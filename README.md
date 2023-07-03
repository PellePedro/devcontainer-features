# Skyramp Dev Container feature:


## Example devcontainer.json
```
{
	"name": "Skyramp Dev",
	"image": "mcr.microsoft.com/devcontainers/base:ubuntu",
	"features": {
		"ghcr.io/devcontainers/features/docker-in-docker:2": {},
		"ghcr.io/pellepedro/devcontainer-features/skyramp:1": {},
		"ghcr.io/devcontainers/features/go:1": {},
		"ghcr.io/devcontainers/features/python:1": {},
	},
}

```

