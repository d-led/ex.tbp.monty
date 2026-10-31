"""Two shapes, so the classifier can be asked without a Monty checkout.

Not Monty's code, and not meant to be: one class that defines behaviour and one
`Protocol` that defines an interface, which is the distinction the census exists
to draw. A test that used Monty's own classes would need the checkout that
nothing in the build may need.
"""

from typing import Protocol


class Recorder:
    """A class with a body, and therefore work to port."""

    def __init__(self, name: str) -> None:
        self.name = name

    def record(self, observations: list) -> list:
        return observations


class Sensor(Protocol):
    """A `Protocol`: an interface, and nothing to port."""

    def step(self, actions: list) -> list: ...
