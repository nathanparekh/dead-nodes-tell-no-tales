#!/usr/bin/env python3
"""Checkpoint dispatcher: reads '<target_id> <export_path>' lines from a FIFO. No shell."""

import logging
import os
import subprocess

FIFO = "/tmp/pipe"
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def checkpoint(target_id: str, export_path: str) -> None:
    subprocess.run(
        ["sudo", "podman", "container", "checkpoint", target_id,
         "-e", export_path, "--tcp-established", "--leave-running"],
        check=True,
    )


def main() -> None:
    if not os.path.exists(FIFO):
        os.mkfifo(FIFO, 0o600)
    while True:
        with open(FIFO) as fifo:            # blocks until a writer connects
            for line in fifo:               # loop ends when that writer closes
                parts = line.split(maxsplit=1)
                if len(parts) != 2:
                    logging.warning("ignored: expected '<target_id> <export_path>', got %r", line.strip())
                    continue
                target_id, export_path = parts[0], parts[1].strip()
                try:
                    checkpoint(target_id, export_path)
                    logging.info("checkpointed %s -> %s", target_id, export_path)
                except subprocess.CalledProcessError as e:
                    logging.error("checkpoint failed for %s (exit %s)", target_id, e.returncode)


if __name__ == "__main__":
    main()