# VisionServe update helpers for a machine that runs the Docker image and/or the Python client.
#
# Install (once):
#   curl -fsSL https://raw.githubusercontent.com/mtbui2010/visionserve/main/deploy/visionserve-update.sh \
#     -o ~/.visionserve-update.sh
#   echo 'source ~/.visionserve-update.sh' >> ~/.bashrc && source ~/.bashrc     # or ~/.zshrc
#
#   update_visionserve [container] [image]   pull the newest image, recreate the container with
#                                            the same ports, volumes, GPU, restart policy,
#                                            VISIONSERVE_* env and command (default: visionserve)
#   update_visionserve_pypi [extras]         upgrade the Python client in the active env
#                                            (e.g. update_visionserve_pypi images)
#
# A container started from a pinned tag (:v0.1.18-cpu) gets nothing new from pulling that tag
# again; pass the tag to move to:  update_visionserve visionserve mtbui2010/visionserve:latest

update_visionserve() {
  local name="${1:-visionserve}" image="$2"
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "update_visionserve: no container named '$name' (docker ps -a)" >&2
    return 1
  fi
  [ -n "$image" ] || image=$(docker inspect -f '{{.Config.Image}}' "$name")
  case "$image" in
    *:v[0-9]*) echo "note: '$image' is a pinned version; pass a newer tag, e.g." \
                    "update_visionserve $name mtbui2010/visionserve:latest" ;;
  esac

  # Settings of the running container, to recreate it the same way.
  local old_id ports mounts gpus restart envs cmd
  old_id=$(docker inspect -f '{{.Image}}' "$name")
  ports=$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}-p {{if .HostIp}}{{.HostIp}}:{{end}}{{.HostPort}}:{{$p}} {{end}}{{end}}' "$name")
  # Bind mounts, named volumes and the anonymous volume the image declares for /root/.models:
  # `docker rm` keeps volumes, so mounting the same one by name keeps the pulled models.
  mounts=$(docker inspect -f '{{range .Mounts}}-v {{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}:{{.Destination}}{{if not .RW}}:ro{{end}} {{end}}' "$name")
  gpus=$(docker inspect -f '{{if .HostConfig.DeviceRequests}}--gpus all{{end}}' "$name")
  restart=$(docker inspect -f '{{with .HostConfig.RestartPolicy.Name}}{{if ne . "no"}}--restart {{.}}{{end}}{{end}}' "$name")
  # Only VISIONSERVE_* variables set with -e, not the ones the image itself defines.
  envs=$(docker inspect -f '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$name" | grep '^VISIONSERVE_' |
         grep -vxF -f <(docker image inspect -f '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$old_id") |
         sed 's/^/-e /' | tr '\n' ' ')
  # Keep a custom command (e.g. `serve --tensorrt`) only if it differs from the image default.
  if [ "$(docker inspect -f '{{json .Config.Cmd}}' "$name")" != "$(docker image inspect -f '{{json .Config.Cmd}}' "$old_id")" ]; then
    cmd=$(docker inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "$name")
  fi

  echo "=== pull $image"
  docker pull "$image" || return 1
  if [ "$(docker image inspect -f '{{.Id}}' "$image")" = "$old_id" ] && [ "$image" = "$(docker inspect -f '{{.Config.Image}}' "$name")" ]; then
    echo "=== '$name' already runs the newest $image"
    docker exec "$name" visionserve version 2>/dev/null | head -1
    return 0
  fi

  echo "=== recreate $name: $gpus $ports$mounts$restart $envs$image $cmd"
  docker rm -f "$name" >/dev/null || return 1
  # shellcheck disable=SC2086  # the option strings are meant to split into words
  docker run -d --name "$name" $gpus $ports $mounts $restart $envs "$image" $cmd >/dev/null || {
    echo "update_visionserve: docker run failed; the old image is still here: $old_id" >&2
    return 1
  }
  sleep 2
  docker exec "$name" visionserve version 2>/dev/null | head -1
  if [ "$(docker inspect -f '{{.Image}}' "$name")" != "$old_id" ]; then
    echo "=== done. Old image (remove when happy): docker rmi $old_id"
  else
    echo "=== done."
  fi
}

update_visionserve_pypi() {
  local pkg=visionserve loc
  [ -n "$1" ] && pkg="visionserve[$1]"
  loc=$(python -m pip show visionserve 2>/dev/null | sed -n 's/^Editable project location: //p')
  if [ -n "$loc" ]; then
    echo "visionserve is installed from source ($loc): run 'git -C \"$loc\" pull' instead"
    return 1
  fi
  echo "=== $(command -v python): pip install -U $pkg"
  python -m pip install -U "$pkg" || return 1
  python -c "import visionserve; print('visionserve', visionserve.__version__)"
}
