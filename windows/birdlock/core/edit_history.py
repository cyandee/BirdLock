"""Bounded operation history. Snapshots own edit state, never media bytes."""
from collections import deque
from dataclasses import dataclass


@dataclass
class EditState:
    key: object
    value: object


class EditHistory:
    def __init__(self, limit=40):
        self.before = deque(maxlen=limit)
        self.after = deque(maxlen=limit)
        self.current = None
        self.gesture = None
        self.grouping = False

    def reset(self, state=None):
        self.before.clear();self.after.clear()
        self.current = state
        self.gesture = None
        self.grouping = False

    def begin(self):
        if not self.grouping:
            self.grouping = True
            self.gesture = self.current

    def update(self, state):
        if self.current is None:
            self.current = state
            return
        if state.key == self.current.key:
            return
        if not self.grouping:
            self.before.append(self.current)
            self.after.clear()
        self.current = state

    def end(self):
        if self.grouping and self.gesture and self.current and self.gesture.key != self.current.key:
            self.before.append(self.gesture)
            self.after.clear()
        self.gesture = None
        self.grouping = False

    def step(self, redo=False):
        self.end()
        source,destination=(self.after,self.before) if redo else (self.before,self.after)
        if not source or self.current is None:
            return None
        destination.append(self.current)
        self.current=source.pop()
        return self.current.value
