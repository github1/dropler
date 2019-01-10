# dropler

Dropler is a script which assists with bootstrapping docker enabled digital ocean droplets.

## Options
- `-d` — Set the dir to upload from
- `-n` — Set the droplet name

## Commands
- `up` — Creates a Docker enabled DigitalOcean droplet
- `dns` — Creates an A record pointing to the droplets public ipv4 address
- `provision` — Rsyncs local source code and runs docker-compose on the droplet
- `restart` — Restarts the containers on on the droplet
- `status` — Shows the status of the droplet and ipv4 address
- `down` — Destroys the droplet/docker-compose services
- `ssh` — Connects to the droplet via SSH
- `logs` — Tails logs of containers on the droplet
