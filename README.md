# Self-Hosted Neon Control Plane


### Run:

```
docker build -t compute_hook .

docker run --rm --name=compute_hook -p 3000:3000 --network=neon \
    -e storcon_dsn="$storcon_dsn" -e compute_dsn="$compute_dsn" \
  compute_hook:latest
```
or

```
export compute_dsn="{your compute node}"
export storcon_dsn="{storage controller database}"
cargo run
```


### ToDo:
- [ ] Custom error handling
- [ ] Not have to use Neon structs/types
