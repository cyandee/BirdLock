//! Read-only IMU extraction. No stabilization, synchronization fitting or network access.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    io::{self, BufWriter, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{Arc, atomic::AtomicBool},
};
use telemetry_parser::{
    Input, InputOptions,
    tags_impl::{GetWithType, GroupId, TagId, TagValue},
    util::{self, IMUData},
};

const SCHEMA: u32 = 1;
const MAX_SAMPLES: usize = 2_000_000;
const MAX_PROJECT: u64 = 128 * 1024 * 1024;
const MAX_INFLATED: usize = 128 * 1024 * 1024;

#[derive(Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Sample {
    t: f64,
    gyro: [f64; 3],
    #[serde(skip_serializing_if = "Option::is_none")]
    accel: Option<[f64; 3]>,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Report {
    schema: u32,
    parser: String,
    camera_brand: String,
    camera_model: Option<String>,
    gyro_unit: String,
    timestamp_unit: String,
    orientation: String,
    source_orientation: Option<String>,
    imu_frame: String,
    camera_frame: String,
    imu_to_camera: [[f64; 3]; 3],
    metadata_frame_count: usize,
    gyroscope_frame_count: usize,
    timestamps_accurate: bool,
    sony_packet_timed: bool,
    partial: bool,
    frame_readout_seconds: Option<f64>,
    frame_readout_direction: Option<String>,
    video: Option<Value>,
    samples: Vec<Sample>,
    raw_metadata_frames: Vec<Value>,
    warnings: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_settings: Option<Value>,
}

fn empty_report(parser: &str) -> Report {
    Report {
        schema: SCHEMA,
        parser: parser.into(),
        camera_brand: String::new(),
        camera_model: None,
        gyro_unit: "rad/s".into(),
        timestamp_unit: "s".into(),
        orientation: "XYZ".into(),
        source_orientation: None,
        imu_frame: "gyroflow-x-up-y-left-z-back".into(),
        camera_frame: "opencv-x-right-y-down-z-forward".into(),
        imu_to_camera: [[0., -1., 0.], [-1., 0., 0.], [0., 0., -1.]],
        metadata_frame_count: 0,
        gyroscope_frame_count: 0,
        timestamps_accurate: false,
        sony_packet_timed: false,
        partial: false,
        frame_readout_seconds: None,
        frame_readout_direction: None,
        video: None,
        samples: vec![],
        raw_metadata_frames: vec![],
        warnings: vec![],
        project_settings: None,
    }
}

fn fail(message: impl Into<String>) -> io::Error {
    io::Error::other(message.into())
}

fn valid_orientation(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 3
        && b.iter().all(|x| b"XYZxyz".contains(x))
        && b[0].to_ascii_uppercase() != b[1].to_ascii_uppercase()
        && b[0].to_ascii_uppercase() != b[2].to_ascii_uppercase()
        && b[1].to_ascii_uppercase() != b[2].to_ascii_uppercase()
}

fn orient(v: [f64; 3], s: &str) -> [f64; 3] {
    let mut out = [0.; 3];
    for (i, c) in s.bytes().enumerate() {
        let index = match c.to_ascii_uppercase() {
            b'X' => 0,
            b'Y' => 1,
            _ => 2,
        };
        out[i] = v[index] * if c.is_ascii_lowercase() { -1. } else { 1. };
    }
    out
}

fn normalize(mut data: Vec<IMUData>, orientation: Option<&str>) -> io::Result<Vec<Sample>> {
    if data.len() > MAX_SAMPLES {
        return Err(fail("Too many IMU readings (maximum 2,000,000)"));
    }
    if let Some(s) = orientation {
        if !valid_orientation(s) {
            return Err(fail("Invalid IMU axis orientation"));
        }
    }
    data.sort_by(|a, b| a.timestamp_ms.total_cmp(&b.timestamp_ms));
    let mut result = Vec::with_capacity(data.len());
    for item in data {
        let Some(g) = item.gyro else { continue };
        if !item.timestamp_ms.is_finite() || !g.iter().all(|v| v.is_finite()) {
            return Err(fail("Non-finite IMU data"));
        }
        let t = item.timestamp_ms / 1000.;
        if result.last().is_some_and(|s: &Sample| t <= s.t) {
            continue;
        }
        let gyro = g.map(f64::to_radians);
        let accel = item.accl.filter(|v| v.iter().all(|v| v.is_finite()));
        result.push(Sample {
            t,
            gyro: orientation.map(|s| orient(gyro, s)).unwrap_or(gyro),
            accel: accel.map(|a| orientation.map(|s| orient(a, s)).unwrap_or(a)),
        });
    }
    Ok(result)
}

// The Sony tags store an offset in device ticks and a gyro sample frequency.
// Decode those units before assigning each reading its packet's own sensor clock.
fn sony_packet_times(input: &Input, imu: &mut [IMUData]) -> bool {
    let Some(frames) = input.samples.as_ref() else {
        return false;
    };
    let mut times = Vec::with_capacity(imu.len());
    for frame in frames {
        let Some(group) = frame
            .tag_map
            .as_ref()
            .and_then(|m| m.get(&GroupId::Gyroscope))
        else {
            continue;
        };
        let count = match group.get(&TagId::Data).map(|d| &d.value) {
            Some(TagValue::Vec_Vector3_i16(v)) => v.get().len(),
            Some(TagValue::Vec_Vector3_f32(v)) => v.get().len(),
            Some(TagValue::Vec_TimeVector3_f64(v)) => v.get().len(),
            _ => 0,
        };
        if count == 0 {
            continue;
        }
        let (Some(offset), Some(frequency)) = (
            group.get_t(TagId::TimeOffset) as Option<&f64>,
            group.get_t(TagId::Frequency) as Option<&i32>,
        ) else {
            return false;
        };
        if *frequency <= 0 {
            return false;
        }
        let ticks = (group.get_t(TagId::Unknown(0xe436)) as Option<&i32>)
            .copied()
            .filter(|v| *v > 0)
            .unwrap_or(1_000_000) as f64;
        let offset_us = (offset * 1000. * (1_000_000. / ticks)).round();
        for i in 0..count {
            times.push(
                frame.timestamp_ms + offset_us / 1000. + i as f64 * 1000. / *frequency as f64,
            );
        }
    }
    if times.is_empty() || times.len() != imu.len() {
        return false;
    }
    for (sample, t) in imu.iter_mut().zip(times) {
        sample.timestamp_ms = t;
    }
    true
}

// The generic normalizer treats Sony's scale as LSB/(deg/s). Recent Sony files
// can explicitly mark LSB/(rad/s); respect that tag and the valid factory bias.
// Work in the same packet order as the official normalizer and only apply a
// correction when every gyro reading can be accounted for.
fn sony_sensor_units(input: &Input, imu: &mut [IMUData], override_axes: Option<&str>) -> bool {
    let Some(frames) = input.samples.as_ref() else {
        return false;
    };
    let mut corrections = Vec::new();
    for frame in frames {
        let Some(group) = frame
            .tag_map
            .as_ref()
            .and_then(|m| m.get(&GroupId::Gyroscope))
        else {
            continue;
        };
        let count = match group.get(&TagId::Data).map(|d| &d.value) {
            Some(TagValue::Vec_Vector3_i16(v)) => v.get().len(),
            _ => 0,
        };
        if count == 0 {
            continue;
        }
        let radians = (group.get_t(TagId::Unknown(0xe438)) as Option<&bool>)
            .copied()
            .unwrap_or(false);
        let factor = if radians {
            180. / std::f64::consts::PI
        } else {
            1.
        };
        let scale = (group.get_t(TagId::Scale) as Option<&f32>)
            .copied()
            .unwrap_or(1.) as f64;
        if !scale.is_finite() || scale <= 0. {
            return false;
        }
        let mut bias = [0.; 3];
        let valid =
            (group.get_t(TagId::Unknown(0xe43e)) as Option<&u16>).is_some_and(|v| v & 0x8000 != 0);
        if valid {
            if let Some(TagValue::Vector3_i16(v)) =
                group.get(&TagId::Unknown(0xe43d)).map(|d| &d.value)
            {
                let v = v.get();
                bias = [v.x as f64 / scale, v.y as f64 / scale, v.z as f64 / scale];
                let source = (group.get_t(TagId::Orientation) as Option<&String>)
                    .cloned()
                    .unwrap_or_else(|| "XYZ".into());
                let axes = override_axes
                    .map(String::from)
                    .unwrap_or_else(|| input.normalize_imu_orientation(source));
                if !valid_orientation(&axes) {
                    return false;
                }
                bias = orient(bias, &axes);
            }
        }
        corrections.push((count, factor, bias));
    }
    if corrections.iter().map(|x| x.0).sum::<usize>() != imu.len() {
        return false;
    }
    let mut index = 0;
    for (count, factor, bias) in corrections {
        for item in &mut imu[index..index + count] {
            if let Some(ref mut gyro) = item.gyro {
                for axis in 0..3 {
                    gyro[axis] = (gyro[axis] - bias[axis]) * factor;
                }
            }
        }
        index += count;
    }
    true
}

fn metadata_frames(input: &Input) -> Vec<Value> {
    let mut frames = vec![];
    if let Some(samples) = &input.samples {
        for sample in samples {
            let Some(groups) = &sample.tag_map else {
                continue;
            };
            let mut object = serde_json::Map::new();
            for (group, map) in groups {
                let name = group.to_string();
                if ![
                    "Default",
                    "Imager",
                    "Lens",
                    "IBIS",
                    "LensOSS",
                    "LensDistortion",
                    "LensBreathing",
                    "CameraOrientation",
                    "ImageOrientation",
                ]
                .contains(&name.as_str())
                {
                    continue;
                }
                let mut values = serde_json::Map::new();
                for (tag, entry) in map {
                    if *group == GroupId::Default
                        && ![
                            TagId::SensorWidth,
                            TagId::SensorHeight,
                            TagId::FrameRate,
                            TagId::ImageStabilizer,
                            // GoPro's explicit digital field of view and HyperSmooth flag.
                            TagId::Unknown(0x56464f56),
                            TagId::Unknown(0x45495341),
                        ]
                        .contains(tag)
                    {
                        continue;
                    }
                    if *tag == TagId::SerialNumber {
                        continue;
                    }
                    if let Ok(value) = serde_json::to_value(&entry.value) {
                        values.insert(tag.to_string(), value);
                    }
                }
                if !values.is_empty() {
                    object.insert(name, Value::Object(values));
                }
            }
            if !object.is_empty() {
                object.insert("t".into(), json!(sample.timestamp_ms / 1000.));
                object.insert("duration".into(), json!(sample.duration_ms / 1000.));
                frames.push(Value::Object(object));
            }
        }
    }
    frames
}

fn validate_gcsv(file: &mut fs::File) -> io::Result<()> {
    let mut reader = csv::ReaderBuilder::new()
        .has_headers(false)
        .flexible(true)
        .trim(csv::Trim::All)
        .from_reader(file);
    let mut body = false;
    let mut count = 0usize;
    for row in reader.records() {
        let row = row.map_err(|e| fail(format!("Invalid GCSV row: {e}")))?;
        if row.len() == 1 && !body {
            continue;
        }
        if !body {
            if row.get(0).is_some_and(|s| s == "t" || s == "time") {
                body = true;
                continue;
            }
            if row.len() != 2 {
                return Err(fail("Invalid GCSV header"));
            }
            let (key, value) = (&row[0], &row[1]);
            if ["tscale", "gscale", "ascale", "mscale"].contains(&key) {
                let value = value
                    .parse::<f64>()
                    .map_err(|_| fail("Invalid GCSV scale"))?;
                if !value.is_finite() || value <= 0. {
                    return Err(fail("GCSV scales must be finite and positive"));
                }
            }
            if key == "orientation" && !valid_orientation(value) {
                return Err(fail("Invalid GCSV orientation"));
            }
        } else {
            if row.len() < 4 {
                return Err(fail("GCSV readings require time and three gyro axes"));
            }
            for value in row.iter() {
                let value = value
                    .parse::<f64>()
                    .map_err(|_| fail("GCSV reading is not a number"))?;
                if !value.is_finite() {
                    return Err(fail("Non-finite GCSV reading"));
                }
            }
            count += 1;
            if count > MAX_SAMPLES {
                return Err(fail("Too many GCSV readings"));
            }
        }
    }
    if !body || count == 0 {
        return Err(fail("GCSV contains no gyroscope readings"));
    }
    Ok(())
}

fn parse_file(path: &Path, probe: bool) -> io::Result<Report> {
    parse_file_oriented(path, probe, None)
}
fn parse_file_oriented(
    path: &Path,
    probe: bool,
    override_axes: Option<&str>,
) -> io::Result<Report> {
    if path
        .extension()
        .is_some_and(|x| x.eq_ignore_ascii_case("gyroflow"))
    {
        return parse_project(path, probe);
    }
    let mut file = fs::File::open(path)?;
    let size = file.metadata()?.len();
    if size == 0 || size > 100 * 1024 * 1024 * 1024 {
        return Err(fail("Empty or unsupported-size telemetry source"));
    }
    let mut header = [0u8; 16];
    let count = file.read(&mut header)?;
    file.seek(SeekFrom::Start(0))?;
    if header[..count].starts_with(b"GYROFLOW IMU LOG")
        || header[..count].starts_with(b"CAMERA IMU LOG")
    {
        validate_gcsv(&mut file)?;
        file.seek(SeekFrom::Start(0))?;
    }
    let video=util::get_video_metadata(&mut file,size as usize).ok().map(|v|json!({"width":v.width,"height":v.height,"fps":v.fps,"durationSeconds":v.duration_s,"rotationDegrees":v.rotation}));
    file.seek(SeekFrom::Start(0))?;
    let mut options = InputOptions::default();
    options.probe_only = probe;
    let input = Input::from_stream_with_options(
        &mut file,
        size as usize,
        path,
        |_| (),
        Arc::new(AtomicBool::new(false)),
        options,
    )?;
    if input.samples.is_none() {
        return Err(fail(format!(
            "{} telemetry was recognized but its metadata could not be parsed",
            input.parser_name()
        )));
    }
    let mut report = empty_report(input.parser_name());
    report.camera_brand = input.camera_type();
    report.camera_model = input.camera_model().cloned();
    report.timestamps_accurate = input.has_accurate_timestamps();
    report.partial = probe;
    report.video = video;
    report.metadata_frame_count = input.samples.as_ref().map_or(0, Vec::len);
    report.gyroscope_frame_count = input.samples.as_ref().map_or(0, |v| {
        v.iter()
            .filter(|x| {
                x.tag_map
                    .as_ref()
                    .is_some_and(|m| m.contains_key(&GroupId::Gyroscope))
            })
            .count()
    });
    if let Some(readout) = input.frame_readout_time() {
        let horizontal = readout.abs() >= 10000.;
        report.frame_readout_seconds =
            Some((readout.abs() - if horizontal { 10000. } else { 0. }) / 1000.);
        report.frame_readout_direction = Some(
            match (horizontal, readout < 0.) {
                (false, false) => "TopToBottom",
                (false, true) => "BottomToTop",
                (true, false) => "LeftToRight",
                (true, true) => "RightToLeft",
            }
            .into(),
        );
    }
    if let Some(samples) = &input.samples {
        for sample in samples {
            if let Some(orientation) = sample
                .tag_map
                .as_ref()
                .and_then(|g| g.get(&GroupId::Gyroscope))
                .and_then(|m| m.get_t(TagId::Orientation) as Option<&String>)
            {
                report.source_orientation = Some(orientation.clone());
                break;
            }
        }
    }
    let mut imu = util::normalized_imu_interpolated(&input, override_axes.map(String::from))?;
    if input.camera_type() == "Sony" {
        if !imu.is_empty() && !sony_sensor_units(&input, &mut imu, override_axes) {
            return Err(fail(
                "Sony gyro unit/bias packets could not be matched safely",
            ));
        }
        report.sony_packet_timed = sony_packet_times(&input, &mut imu);
        if !imu.is_empty() && !report.sony_packet_timed {
            report.warnings.push("Sony packet clocks unavailable; optical synchronization must verify the uniform timeline".into());
        }
    }
    report.samples = normalize(imu, None)?;
    report.raw_metadata_frames = metadata_frames(&input);
    if report.samples.is_empty() {
        report
            .warnings
            .push("No gyroscope samples were present".into());
    }
    Ok(report)
}

fn inflate(text: &str) -> io::Result<Vec<u8>> {
    let compressed = base91::slice_decode(text.as_bytes());
    let reader = flate2::read::ZlibDecoder::new(&compressed[..]);
    let mut out = Vec::new();
    reader.take(MAX_INFLATED as u64 + 1).read_to_end(&mut out)?;
    if out.len() > MAX_INFLATED {
        return Err(fail("Compressed gyro project data exceeds 128 MiB"));
    }
    Ok(out)
}

fn local_reference(project: &Path, value: &str) -> io::Result<PathBuf> {
    let mut value = value.strip_prefix("file://").unwrap_or(value).to_owned();
    if value.contains("://") {
        return Err(fail("Remote gyro references are not supported"));
    }
    let mut decoded = Vec::new();
    let mut bytes = value.bytes();
    while let Some(c) = bytes.next() {
        if c == b'%' {
            let a = bytes.next().and_then(|x| (x as char).to_digit(16));
            let b = bytes.next().and_then(|x| (x as char).to_digit(16));
            if let (Some(a), Some(b)) = (a, b) {
                decoded.push((a * 16 + b) as u8);
            } else {
                return Err(fail("Invalid escaped file path"));
            }
        } else {
            decoded.push(c);
        }
    }
    value = String::from_utf8(decoded).map_err(|_| fail("Invalid UTF-8 file reference"))?;
    #[cfg(windows)]
    if value.starts_with('/') && value.as_bytes().get(2) == Some(&b':') {
        value.remove(0);
    }
    let path = PathBuf::from(value);
    Ok(if path.is_absolute() {
        path
    } else {
        project.parent().unwrap_or(Path::new(".")).join(path)
    })
}

fn parse_project(path: &Path, probe: bool) -> io::Result<Report> {
    if fs::metadata(path)?.len() > MAX_PROJECT {
        return Err(fail("Gyroflow project is larger than 128 MiB"));
    }
    let project: Value = serde_json::from_reader(fs::File::open(path)?)?;
    let source = project
        .get("gyro_source")
        .ok_or_else(|| fail("No gyro_source in Gyroflow project"))?;
    let mut imu: Vec<IMUData> = vec![];
    if let Some(raw) = source.get("raw_imu") {
        if raw.is_array() {
            imu = serde_json::from_value(raw.clone())?;
        } else if let Some(text) = raw.as_str() {
            let bytes = inflate(text)?;
            imu = bincode::serde::decode_from_slice::<Vec<IMUData>, _>(
                &bytes,
                bincode::config::legacy(),
            )
            .map_err(|e| fail(e.to_string()))?
            .0;
        }
    }
    if imu.is_empty() {
        if let Some(text) = source.get("file_metadata").and_then(Value::as_str) {
            let metadata: Value =
                ciborium::from_reader(&inflate(text)?[..]).map_err(|e| fail(e.to_string()))?;
            if let Some(raw) = metadata.get("raw_imu") {
                imu = serde_json::from_value(raw.clone())?;
            }
        }
    }
    let settings = json!({"imuOrientation":source.get("imu_orientation"),"offsets":project.get("offsets"),"gyroOffsets":source.get("offsets"),"gyroBias":source.get("gyro_bias"),
        "rotation":source.get("rotation"),"accRotation":source.get("acc_rotation"),"lpf":source.get("lpf"),"mf":source.get("mf")});
    let orientation = source
        .get("imu_orientation")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    if orientation.is_some_and(|s| !valid_orientation(s)) {
        return Err(fail("Invalid project IMU orientation"));
    }
    if imu.is_empty() {
        let value = source
            .get("filepath")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| fail("Gyroflow project contains no embedded IMU or source reference"))?;
        let reference = local_reference(path, value)?;
        if reference
            .extension()
            .is_some_and(|s| s.eq_ignore_ascii_case("gyroflow"))
        {
            return Err(fail("Nested gyro project references are not supported"));
        }
        let mut report = parse_file_oriented(&reference, probe, orientation)?;
        report.project_settings = Some(settings);
        report.warnings.push(
            "Imported project offsets, bias, rotation and filters are metadata; verify alignment and apply settings explicitly".into(),
        );
        return Ok(report);
    }
    let mut report = empty_report("GyroflowProject");
    report.partial = probe;
    report.source_orientation = orientation.map(String::from);
    report.samples = normalize(imu, orientation)?;
    report.project_settings = Some(settings);
    if probe && report.samples.len() > 10 {
        report.samples.truncate(10);
    }
    report.warnings.push(
        "Imported project offsets, bias, rotation and filters are metadata; verify alignment and apply settings explicitly".into(),
    );
    Ok(report)
}

fn run() -> io::Result<()> {
    let mut args = std::env::args_os().skip(1);
    let mut input = None;
    let mut output = None;
    let mut probe = false;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--input") => input = args.next().map(PathBuf::from),
            Some("--output") => output = args.next().map(PathBuf::from),
            Some("--probe") => probe = true,
            Some("--version") => {
                println!("birdlock-telemetry 1.0.0 schema 1 telemetry-parser 19bc11f");
                return Ok(());
            }
            Some("--help") | Some("-h") => {
                println!(
                    "birdlock-telemetry --input FILE [--output JSON] [--probe]\nReads embedded Sony/GoPro/DJI telemetry, GCSV, JSONL or Gyroflow project IMU. Output units: seconds and rad/s."
                );
                return Ok(());
            }
            _ => return Err(fail("Unknown argument; use --help")),
        }
    }
    let input = input.ok_or_else(|| fail("Missing --input"))?;
    if output
        .as_ref()
        .is_some_and(|path| path.canonicalize().ok() == input.canonicalize().ok())
    {
        return Err(fail("The output path must not replace the source file"));
    }
    let report = parse_file(&input, probe)?;
    if let Some(path) = output {
        let parent = path.parent().unwrap_or(Path::new("."));
        fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(".telemetry-{}.part", std::process::id()));
        let result = (|| {
            let mut f = BufWriter::new(fs::File::create(&temporary)?);
            serde_json::to_writer(&mut f, &report)?;
            f.flush()?;
            drop(f);
            if path.exists() {
                fs::remove_file(&path)?;
            }
            fs::rename(&temporary, &path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result?;
    } else {
        let mut out = BufWriter::new(io::stdout().lock());
        serde_json::to_writer(&mut out, &report)?;
        out.write_all(b"\n")?;
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{}", json!({"error":error.to_string()}));
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn degrees_seconds_and_axis_mapping() {
        let values = vec![IMUData {
            timestamp_ms: 1250.,
            gyro: Some([180., 90., -45.]),
            accl: Some([1., 2., 3.]),
            magn: None,
        }];
        let v = normalize(values, Some("YxZ")).unwrap();
        assert_eq!(v[0].t, 1.25);
        assert!((v[0].gyro[0] - std::f64::consts::FRAC_PI_2).abs() < 1e-12);
        assert!((v[0].gyro[1] + std::f64::consts::PI).abs() < 1e-12);
        assert_eq!(v[0].accel, Some([2., -1., 3.]));
        assert!(!valid_orientation("XXZ"));
    }
    #[test]
    fn duplicate_and_invalid_samples() {
        let item = IMUData {
            timestamp_ms: 0.,
            gyro: Some([0.; 3]),
            accl: None,
            magn: None,
        };
        assert_eq!(
            normalize(vec![item.clone(), item.clone()], None)
                .unwrap()
                .len(),
            1
        );
        let mut bad = item;
        bad.timestamp_ms = f64::NAN;
        assert!(normalize(vec![bad], None).is_err());
    }

    #[test]
    fn reads_official_project_compression_formats() {
        let imu = vec![IMUData {
            timestamp_ms: 1250.,
            gyro: Some([180., 90., -45.]),
            accl: None,
            magn: None,
        }];
        let compress = |bytes: &[u8]| {
            let mut encoder =
                flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
            encoder.write_all(bytes).unwrap();
            String::from_utf8(base91::slice_encode(&encoder.finish().unwrap())).unwrap()
        };
        let bincode = bincode::serde::encode_to_vec(&imu, bincode::config::legacy()).unwrap();
        let mut cbor = Vec::new();
        ciborium::into_writer(&json!({"raw_imu":imu}), &mut cbor).unwrap();
        for (index, source) in [
            json!({"raw_imu":compress(&bincode)}),
            json!({"file_metadata":compress(&cbor)}),
        ]
        .iter()
        .enumerate()
        {
            let path = std::env::temp_dir().join(format!(
                "birdlock-gyro-test-{}-{index}.gyroflow",
                std::process::id()
            ));
            fs::write(
                &path,
                serde_json::to_vec(&json!({"gyro_source":source})).unwrap(),
            )
            .unwrap();
            let result = parse_project(&path, false);
            let _ = fs::remove_file(path);
            let report = result.unwrap();
            assert_eq!(report.samples.len(), 1);
            assert_eq!(report.samples[0].t, 1.25);
            assert!((report.samples[0].gyro[0] - std::f64::consts::PI).abs() < 1e-12);
        }
    }

    #[test]
    fn camera_frame_conversion_includes_quarter_turn_and_forward_axis() {
        let m = empty_report("test").imu_to_camera;
        let v = [1., 2., 3.];
        let output = m.map(|row| row.iter().zip(v).map(|(a, b)| a * b).sum::<f64>());
        assert_eq!(output, [-2., -1., -3.]);
    }
}
