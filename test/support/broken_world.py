#!/usr/bin/env python3
"""A peer that refuses to start, the way a simulator with a missing dependency
does: it says why on stderr and exits non-zero before reading a frame.

The port reports a world that went away as `{:simulator_exited, 1}`, so a run
against this file fails while it is still resetting its world — before it has
taken a step, and therefore before anything else could have recorded that it
happened. That is the case this file exists to reproduce.
"""

import sys

sys.stderr.write("this world will not start: a dependency is missing\n")
sys.exit(1)
