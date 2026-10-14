"""Colours and the dark style (mirrors the macOS app's Theme)."""
from PySide6.QtGui import QColor, QPalette
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


STYLE = f"""
QWidget {{ color: {hexa(TEXT)}; font-size: 13px; }}
QMainWindow, QWidget#canvas {{ background: {hexa(CANVAS)}; }}
QWidget#panel, QScrollArea#inspector, QScrollArea#inspector > QWidget > QWidget {{ background: {hexa(PANEL)}; }}
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
QPushButton#primary:hover {{ background: #ffc85a; }}
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
QCheckBox::indicator {{ width: 15px; height: 15px; }}
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
"""


def apply(app: QApplication):
    app.setStyle("Fusion")
    p = QPalette()
    p.setColor(QPalette.Window, PANEL)
    p.setColor(QPalette.WindowText, TEXT)
    p.setColor(QPalette.Base, QColor(36, 37, 41))
    p.setColor(QPalette.AlternateBase, QColor(44, 45, 50))
    p.setColor(QPalette.Text, TEXT)
    p.setColor(QPalette.Button, QColor(44, 45, 50))
    p.setColor(QPalette.ButtonText, TEXT)
    p.setColor(QPalette.Highlight, ACCENT)
    p.setColor(QPalette.HighlightedText, QColor(20, 20, 20))
    p.setColor(QPalette.ToolTipBase, QColor(42, 43, 47))
    p.setColor(QPalette.ToolTipText, TEXT)
    p.setColor(QPalette.PlaceholderText, TERTIARY)
    app.setPalette(p)
    app.setStyleSheet(STYLE)
