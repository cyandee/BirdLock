"""Runtime colour tokens, Qt styling and native Windows window colours."""
import os
from PySide6.QtCore import QEvent, QObject, QPointF, Qt
from PySide6.QtGui import QColor, QPalette, QPainter, QPen, QPixmap
from PySide6.QtWidgets import QApplication

CANVAS = QColor(19, 20, 22)
PANEL = QColor(28, 29, 32)
CARD = QColor(255, 255, 255, 12)
CARD_STROKE = QColor(255, 255, 255, 18)
ACCENT = QColor(250, 184, 61)       # warm amber, like a bird's eye ring
EYE = QColor(64, 217, 255)
OK = QColor(92, 199, 120)
WARN = QColor(242, 173, 64)
BAD = QColor(235, 92, 84)
MANUAL = QColor(184, 133, 255)
MUSIC = QColor(115, 158, 255)
TEXT = QColor(235, 235, 240)
SECONDARY = QColor(160, 160, 168)
TERTIARY = QColor(110, 110, 118)


def hexa(c: QColor, alpha: float | None = None) -> str:
    a = c.alpha() / 255 if alpha is None else alpha
    return f"rgba({c.red()},{c.green()},{c.blue()},{a:.3f})"


_tokens = {key:value for key,value in globals().copy().items() if key.isupper() and isinstance(value,QColor)}
_dark = {key:QColor(value) for key,value in _tokens.items()}
_light = dict(CANVAS="#f6f5f3", PANEL="#eeece8", TEXT="#252323", SECONDARY="#504940",
              TERTIARY="#6b6159", ACCENT="#b46704", OK="#176435", WARN="#855004",
              BAD="#a12d29", MANUAL="#663d98", MUSIC="#2c58a1", EYE="#06627a")
_is_dark = True


def _style():
    ink = "255,255,255" if _is_dark else "24,20,18"
    float_bg = "#2a2b2f" if _is_dark else "#fffdf8"
    edge = "#3a3b40" if _is_dark else "#bcb4a7"
    return f"""
QWidget {{ color: {hexa(TEXT)}; font-size: 13px; }}
QMainWindow, QDialog, QWidget#canvas {{ background: {hexa(CANVAS)}; }}
QWidget#panel, QScrollArea#inspector, QScrollArea#inspector > QWidget > QWidget {{ background: {hexa(PANEL)}; }}
QToolBar {{ background: {hexa(PANEL)}; border: none; padding: 6px 10px; spacing: 8px; }}
QTextBrowser, QListWidget#importList, QFrame#statusCard {{ background: {hexa(PANEL)}; border: 1px solid {edge}; }}
QFrame#card {{ background: rgba(255,255,255,0.045); border: 1px solid rgba(255,255,255,0.07); border-radius: 10px; }}
QLabel#cardTitle {{ font-weight: 600; font-size: 13px; }}
QLabel#caption {{ color: {hexa(SECONDARY)}; font-size: 12px; }}
QLabel#value {{ color: {hexa(SECONDARY)}; font-family: Consolas, Menlo, monospace; font-size: 12px; }}
QLabel#ok {{ color: {hexa(OK)}; font-size: 12px; }}
QLabel#warn {{ color: {hexa(WARN)}; font-size: 12px; }}
QLabel#manual {{ color: {hexa(MANUAL)}; font-size: 12px; }}
QPushButton {{ background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.10); border-radius: 6px; padding: 4px 10px; }}
QPushButton:hover {{ background: rgba(255,255,255,0.14); }}
QPushButton:pressed {{ background: rgba(255,255,255,0.20); }}
QPushButton:checked {{ background: {hexa(ACCENT, 0.22)}; border-color: {hexa(ACCENT)}; }}
QPushButton:disabled {{ color: {hexa(TERTIARY)}; }}
QPushButton#primary {{ background: {hexa(ACCENT)}; color: #1b1b1b; border: none; font-weight: 600; padding: 6px 14px; }}
QPushButton#primary:hover:enabled {{ background: #ffc85a; }}
QPushButton#primary:disabled {{ background: rgba(255,255,255,0.06); color: {hexa(TERTIARY)}; border: 1px solid rgba(255,255,255,0.08); }}
QPushButton#link {{ background: transparent; border: none; color: {hexa(ACCENT)}; padding: 0; }}
QPushButton#chip {{ padding: 6px 4px; font-size: 12px; }}
QToolButton {{ background: transparent; border: none; border-radius: 6px; padding: 4px; }}
QToolButton:hover {{ background: rgba(255,255,255,0.10); }}
QToolButton:checked {{ background: {hexa(ACCENT, 0.25)}; }}
QComboBox, QLineEdit, QSpinBox, QDoubleSpinBox {{ background: rgba(255,255,255,0.07); border: 1px solid rgba(255,255,255,0.12);
    border-radius: 6px; padding: 3px 8px; selection-background-color: {hexa(ACCENT, 0.5)}; }}
QComboBox QAbstractItemView {{ background: #2a2b2f; border: 1px solid #3a3b40; selection-background-color: {hexa(ACCENT, 0.35)}; }}
QSlider::groove:horizontal {{ height: 4px; background: rgba(255,255,255,0.12); border-radius: 2px; }}
QSlider::sub-page:horizontal {{ background: {hexa(ACCENT)}; border-radius: 2px; }}
QSlider::handle:horizontal {{ background: #e8e8ea; width: 14px; height: 14px; margin: -5px 0; border-radius: 7px; }}
QCheckBox::indicator, QRadioButton::indicator {{ width: 16px; height: 16px; border: 1px solid rgba(255,255,255,0.45);
    background: rgba(255,255,255,0.07); }}
QCheckBox::indicator {{ border-radius: 4px; }}
QRadioButton::indicator {{ border-radius: 8px; }}
QCheckBox::indicator:hover, QRadioButton::indicator:hover {{ border-color: rgba(255,255,255,0.75);
    background: rgba(255,255,255,0.14); }}
QCheckBox::indicator:checked, QRadioButton::indicator:checked {{ border-color: {hexa(ACCENT)};
    background: {hexa(ACCENT, 0.30)}; }}
QTabBar::tab {{ background: transparent; padding: 6px 18px; border-radius: 6px; margin: 2px; }}
QTabBar::tab:selected {{ background: rgba(255,255,255,0.12); }}
QTabWidget::pane {{ border: none; }}
QScrollBar:vertical {{ background: transparent; width: 10px; }}
QScrollBar::handle:vertical {{ background: rgba(255,255,255,0.18); border-radius: 4px; min-height: 30px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
QProgressBar {{ background: rgba(255,255,255,0.10); border: none; border-radius: 3px; height: 6px; text-align: center; }}
QProgressBar::chunk {{ background: {hexa(ACCENT)}; border-radius: 3px; }}
QMenuBar {{ background: {hexa(PANEL)}; }}
QMenuBar::item:selected {{ background: rgba(255,255,255,0.12); }}
QMenu {{ background: #2a2b2f; border: 1px solid #3a3b40; }}
QMenu::item:selected {{ background: {hexa(ACCENT, 0.35)}; }}
QToolTip {{ background: #2a2b2f; color: #eee; border: 1px solid #444; padding: 4px; }}
QStatusBar {{ background: {hexa(PANEL)}; color: {hexa(SECONDARY)}; }}
""".replace("255,255,255", ink).replace("#2a2b2f",float_bg).replace("#3a3b40",edge).replace("color: #eee",f"color: {hexa(TEXT)}")


def _check_image() -> str | None:
    """Small dark tick drawn on the amber checked indicator (rendered once into the data folder)."""
    try:
        from ..core.paths import data_dir
        d = data_dir()
        d.mkdir(parents=True, exist_ok=True)
        p = d / "check.png"
        if not p.exists():
            pm = QPixmap(12, 12)
            pm.fill(Qt.transparent)
            pt = QPainter(pm)
            pt.setRenderHint(QPainter.Antialiasing)
            pen = QPen(QColor("#161616"), 2.2)
            pen.setCapStyle(Qt.RoundCap)
            pen.setJoinStyle(Qt.RoundJoin)
            pt.setPen(pen)
            pt.drawPolyline([QPointF(2.2, 6.6), QPointF(5.0, 9.4), QPointF(9.8, 2.6)])
            pt.end()
            if not pm.save(str(p)):
                return None
        return str(p).replace("\\", "/")
    except Exception:
        return None


def _native_caption(widget):
    if os.name!="nt" or app_platform()!="windows" or not widget.isWindow():
        return
    try:
        import ctypes
        from ctypes import wintypes
        set_attr=ctypes.windll.dwmapi.DwmSetWindowAttribute
        set_attr.argtypes=[wintypes.HWND,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD]
        hwnd=int(widget.winId())
        flag=ctypes.c_int(int(_is_dark))
        def attr(key,value):
            return set_attr(hwnd,key,ctypes.byref(value),ctypes.sizeof(value))
        if attr(20,flag)!=0:
            attr(19,flag)
        for key,color in ((34,ACCENT),(35,PANEL),(36,TEXT)):
            ref=ctypes.c_uint32(color.red()|(color.green()<<8)|(color.blue()<<16))
            attr(key,ref)  # Windows 10 can reject these while supporting the dark flag.
    except (OSError,AttributeError,RuntimeError):
        pass


def app_platform():
    return QApplication.platformName()


class _WindowColours(QObject):
    def eventFilter(self, widget, event):
        from PySide6.QtWidgets import QWidget
        if event.type()==QEvent.Show and isinstance(widget,QWidget) and widget.isWindow():
            _native_caption(widget)
        return False


def apply(app: QApplication, mode=None):
    global _is_dark
    if mode is not None:
        app.setProperty("birdlockAppearance",mode)
    mode=app.property("birdlockAppearance") or "dark"
    if not hasattr(app,"_birdlock_theme"):
        app._birdlock_theme=_WindowColours(app)
        app.installEventFilter(app._birdlock_theme)
        app.styleHints().colorSchemeChanged.connect(lambda _:apply(app) if app.property("birdlockAppearance")=="system" else None)
    _is_dark=mode=="dark" or (mode=="system" and app.styleHints().colorScheme()!=Qt.ColorScheme.Light)
    for key,target in _tokens.items():
        color=QColor(_light.get(key,_dark[key])) if not _is_dark else _dark[key]
        target.setRgba(color.rgba())
    app.setStyle("Fusion")
    p = QPalette()
    p.setColor(QPalette.Window, PANEL)
    p.setColor(QPalette.WindowText, TEXT)
    p.setColor(QPalette.Base, QColor("#242529" if _is_dark else "#fffefa"))
    p.setColor(QPalette.AlternateBase, QColor("#2c2d32" if _is_dark else "#f2ede5"))
    p.setColor(QPalette.Text, TEXT)
    p.setColor(QPalette.Button, QColor("#2c2d32" if _is_dark else "#eee9df"))
    p.setColor(QPalette.ButtonText, TEXT)
    p.setColor(QPalette.Highlight, ACCENT)
    p.setColor(QPalette.HighlightedText, QColor("#141414" if _is_dark else "#ffffff"))
    p.setColor(QPalette.ToolTipBase, QColor("#2a2b2f" if _is_dark else "#fffdf8"))
    p.setColor(QPalette.ToolTipText, TEXT)
    p.setColor(QPalette.PlaceholderText, TERTIARY)
    app.setPalette(p)
    tick = _check_image()
    extra = ""
    if tick:
        extra = (f"QCheckBox::indicator:checked {{ image: url({tick}); }}"
                 f"QRadioButton::indicator:checked {{ image: url({tick}); }}")
    app.setStyleSheet(_style() + extra)
    for widget in app.topLevelWidgets():
        if widget.isVisible():_native_caption(widget)
