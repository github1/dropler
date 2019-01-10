# dropler

Dropler is a script which assists with bootstrapping docker enabled digital ocean droplets.

## Options
- `-d` — Set the dir to upload from (defaults to `.`)
- `-n` — Set the droplet name (defaults to the upload dir name)

## Commands
- `up` — Creates a Docker enabled DigitalOcean droplet
- `dns` — Creates an A record pointing to the droplets public ipv4 address
- `provision` — Rsyncs local source code and runs docker-compose on the droplet
- `restart` — Restarts the containers on on the droplet
- `status` — Shows the status of the droplet and ipv4 address
- `down` — Destroys the droplet/docker-compose services
- `ssh` — Connects to the droplet via SSH
- `logs` — Tails logs of containers on the droplet

### Example

The below command will create a new droplet (with docker and docker-compose installed), rsync the contets of `./example` to the droplet, and run `docker-compose up`.

```bash
./dropler.sh up -d ./example
```
if you make a change to your source, running the below command will rsync the source to the droplet and re-build/re-run the container:
```bash
./dropler.sh provision -d ./example
```
you can get logs from the docker-compose process like so:
```bash
./dropler.sh logs -d ./example
```
and you can ssh into the droplet:
```bash
./dropler.sh ssh -d ./example
```
... finally, to destroy the droplet:
```bash
./dropler.sh down -d ./example
```
