# Copacetic Action

[Marketplace](https://github.com/marketplace/actions/copacetic-action)

This action patches vulnerable containers using [Copa](https://github.com/project-copacetic/copacetic).
Copacetic Action is supported with Copa version 0.3.0 and later.

## Inputs

| Name               | Type   | Required | Default   | Description                                                                           |
| ------------------ | ------ | -------- | --------- | ------------------------------------------------------------------------------------- |
| `image`            | String | True     |           | Image reference to patch                                                              |
| `image-report`     | String | False    |           | Trivy JSON vulnerability report of the image to patch, or a directory of per-platform reports for a multi-platform image (copa v0.11.0 and later). If empty, Copa updates all outdated OS packages (copa v0.7.0 and later) |
| `patched-tag`      | String | True     |           | Patched image tag, or a full image reference such as `ghcr.io/org/app:1.0-patched` (copa v0.12.0 and later) |
| `timeout`          | String | False    | `5m`      | Timeout for `copa patch`                                                              |
| `buildkit-version` | String | False    | `latest`  | Buildkit version                                                                      |
| `copa-version`     | String | False    | `latest`  | Copa version                                                                          |
| `output`           | String | False    |           | Output filename (available using copa-action with copa v0.6.1 and later)              |
| `format`           | String | False    | `openvex` | Output format (available using copa-action with copa v0.6.1 and later)                |
| `custom-socket`    | String | False    |           | Custom Docker socket address (available using copa-action with copa v0.6.1 and later) |
| `max_retries`      | Number | False    | `0`       | Max retries on timeout error                                                          |
| `platform`         | String | False    |           | Comma-separated platforms to patch in a multi-platform image, for example `linux/amd64,linux/arm64`. Other platforms are kept unchanged. Ignored when `image-report` is a directory (copa v0.11.0 and later) |
| `push`             | String | False    | `false`   | Push the patched image, or the patched multi-platform index, to its registry (copa v0.11.0 and later). An empty value means `false` |
| `oci-dir`          | String | False    |           | Directory, relative to the workspace, to write the patched multi-platform index to as an OCI layout. The directory must not exist yet. Cannot be used with `push` (copa v0.12.0 and later) |

When `copa-version` is set, the action checks that it supports the inputs in use and fails early if it doesn't.

The `output` file and the `oci-dir` layout are written by a container running as root, so they are owned by root on the runner. Use `sudo` to change or delete them, for example `sudo chown -R "$(id -u):$(id -g)" <path>`.

> [!NOTE]
> Features that are supported with new Copacetic releases will not neccessarily align with what is supported with Copa Action.
> For example, the `output` file feature was released in Copa v0.5.0, but is supported with Copa Action when using Copa version v0.6.1 and later.

## Outputs

| Name            | Type   | Description                          |
| --------------- | ------ | ------------------------------------ |
| `patched-image` | String | Image reference of the patched image. With `push`, the pushed image or multi-platform index. With `oci-dir`, the name Copa gives the patched index in the layout. Empty when a multi-platform image is patched without `push` or `oci-dir` |

## Ways to connect to Buildkit
> [!NOTE]
Custom Buildkit connection to patch local or private images is only available with Copa-Action versions 0.6.1 and later. For all earlier Copa-Action versions, Buildkit in a container is the default approach, and a version must be supplied as input.

### Option 1: Connect to buildx instance (default)
By default, Copa Action creates its own Buildx instance to connect to for patching public and private images.

### Option 2: Connect using defaults through a custom socket
To patch local images, `copa` is limited to using `docker`'s built-in buildkit service, and must use the [`containerd image store`](https://docs.docker.com/storage/containerd/) feature. To enable this in your Github workflow, use `setup-docker-action`'s [daemon-configuration](https://github.com/docker/setup-docker-action#daemon-configuration) to set `"containerd-snapshotter": true`.

Example:
``` yaml
    - name: Set up Docker
        uses: docker/setup-docker-action@v5
        with:
        daemon-config: |
            {
            "debug": true,
            "experimental": true,
                "features": {
                "containerd-snapshotter": true
                }
            }
    - name: Get socket path
        run: |
            url=$(docker context inspect | jq -r .[0].Endpoints.docker.Host)
            socket_path=$(echo "$url" | awk -F// '{print $2}')
            echo "$socket_path"
            echo "SOCKET=$socket_path" >> $GITHUB_ENV
```

Then, supply the resulting socket path (`$SOCKET`) as the input `custom-socket` for the Copa Action to connect to.
> [!NOTE]
> Copa Action will load the image to the default docker context, not the "setup-docker-action" context.

### Option 3: Buildkit in a container
To connect via buildkit in a container, provide the input `buildkit-version`. Copa Action will create a buildkit container with that version to connect to.
> [!NOTE]
> This approach does not allow for patching of local or private images.


Refer to [Copacetic documentation](https://project-copacetic.github.io/copacetic/website/custom-address) to learn more about connecting Copa to Buildkit.

## Multi-platform images

Copa can patch [multi-platform images](https://project-copacetic.github.io/copacetic/website/multiplatform-patching) with copa v0.11.0 and later. Choose which platforms to patch in one of three ways:

- Set `image-report` to a directory of per-platform Trivy reports. Only the platforms with a report are patched.
- Set `platform` to a comma-separated list of platforms and leave `image-report` empty. Copa updates all outdated OS packages on those platforms.
- Leave both empty to update every platform in the image.

Platforms that are not patched are kept unchanged in the result.

A patched multi-platform image can't be loaded into the classic Docker image store as one image, so tell the action where to put it:

- `push: true` pushes the patched index to `<image repository>:<patched-tag>`, or to the full reference in `patched-tag`. Copa also pushes each patched platform as `<patched-tag>-<arch>`, for example `1.0-patched-arm64`.
- `oci-dir: <directory>` writes the patched index to an OCI layout in the workspace (copa v0.12.0 and later), for later steps to scan, sign or copy to a registry.

Without either, Copa only loads each patched platform into Docker as `<patched-image>-<arch>`. The action can't tell in advance whether an image is multi-platform, so without `push` or `oci-dir` it logs a warning that `patched-image` may be empty whenever the result could be multi-platform: when `image-report` is empty or a directory, or `platform` is set. In those cases `patched-image` is set only if Copa loaded a single image under that name, and is empty otherwise.

Copa pushes only the patched platforms; the patched index points at the original manifests for the platforms it keeps unchanged. Those manifests must already be in the repository you push to, so patch an image in your own registry, or copy it there first as in the example below.

### QEMU

Patching a platform that is not native to the runner, such as `linux/arm64` on an `ubuntu-latest` runner, needs QEMU. Add [docker/setup-qemu-action](https://github.com/docker/setup-qemu-action) before the Copacetic action. When `platform` lists a platform that QEMU doesn't seem to be set up for, the action logs a warning; Copa then fails to patch that platform with its own error.

### Registry credentials

With `push: true`, the action mounts the Docker `config.json` from the runner (`$DOCKER_CONFIG/config.json`, or `~/.docker/config.json`) read-only into its container, so log in first, for example with [docker/login-action](https://github.com/docker/login-action). Every registry credential stored in that file is readable inside the action container, not only the one for the registry you push to. Credential helpers (`credsStore` or `credHelpers`) are not available inside the container, so only credentials stored directly in the file work; the action warns if the file is missing or uses a helper.

### Example

```yaml
jobs:
  patch:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    env:
      SOURCE: docker.io/library/nginx:1.26.3-bookworm
      IMAGE: ghcr.io/${{ github.repository_owner }}/nginx:1.26.3-bookworm
    steps:
      - name: Set up QEMU
        uses: docker/setup-qemu-action@v4

      - name: Login to GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Copy the image to GHCR
        run: docker buildx imagetools create --tag "$IMAGE" "$SOURCE"

      - name: Generate per-platform Trivy reports
        run: |
          mkdir -p reports
          for platform in linux/amd64 linux/arm64; do
            arch=$(echo "$platform" | cut -d'/' -f2)
            docker run --rm -v "$PWD/reports:/reports" aquasec/trivy:0.69.3 image \
              --platform "$platform" --pkg-types os --ignore-unfixed \
              -f json -o "/reports/${arch}.json" "$SOURCE"
          done

      - name: Run Copa action
        id: copa
        # pin to the commit SHA of the first copa-action release with multi-platform support
        uses: project-copacetic/copa-action@<commit-sha> # vX.Y.Z
        with:
          image: ${{ env.IMAGE }}
          image-report: reports
          patched-tag: 1.26.3-bookworm-patched
          push: true
          copa-version: "0.15.0"
          timeout: 15m

      - name: Show the patched index
        env:
          PATCHED_IMAGE: ${{ steps.copa.outputs.patched-image }}
        run: docker buildx imagetools inspect "$PATCHED_IMAGE"
```

> [!NOTE]
> With `push`, the patched platforms are pushed from BuildKit. The default buildx instance and `buildkit-version` both work for remote registries. To push to a registry on `localhost`, use `buildkit-version`, which runs BuildKit on the host network.

## Behaviour changes

- Inputs are passed to the action's script through environment variables instead of being written into it, so shell variables such as `$VAR` in `image`, `image-report`, `patched-tag`, `timeout`, `format`, `output` and `max_retries` are no longer expanded. Use `${{ env.VAR }}` instead. `copa-version`, `custom-socket` and `buildkit-version` are unchanged, so `custom-socket: $SOCKET` still works.
- An empty `output` no longer shifts `max_retries` into its place. Before, the VEX document was written to a file named after `max_retries` (`0` by default) and retries were ignored.
- `patched-image` is now built from the image repository, so it is correct for registries with a port (`localhost:5000/app:1` gave `localhost:<tag>`), digest-pinned images, and a full reference in `patched-tag`. For other images it is unchanged.
- The action runs the `entrypoint.sh` from the action version you use on top of the `copa-action` image for your `copa-version`, so new inputs work with images published for earlier Copa releases.

## Example usage

https://github.com/project-copacetic/copa-action/blob/00f0ef529529d7a7d49a1f3b9f5f5cf54ba2235e/.github/workflows/patch.yaml#L1-L81