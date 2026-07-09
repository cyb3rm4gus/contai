# Wiki Agent

Instructions for the containerized agent go here.

(This file is bind-mounted read-only into the container at /home/agent/CLAUDE.md.
It must exist as a *file* before `docker compose up` — otherwise Docker creates a
directory in its place.)

Avoid running containers because this session exists inside a docker container and container nesting is undesired.
