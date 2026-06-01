#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: CONFIG=<gcw0|rs90|lepus|installer> ./build-container.sh [options] [rebuild.sh args...]
   or: ./build-container.sh [options] <gcw0|rs90|lepus|installer> [rebuild.sh args...]

Builds OpenDingux Buildroot inside a container (CI-like by default).

Options:
  --engine <docker|podman>  Container engine to use
  --image <name[:tag]>      Image name to run (default: ghcr.io/opendingux/retro-toolchain/buildroot)
  --skip-image-build        Do not build the image automatically
  -h, --help                Show this help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"
DOCKERFILE_DIR="${REPO_DIR}/support/docker"

ENGINE="${CONTAINER_ENGINE:-}"
IMAGE="${CONTAINER_IMAGE:-ghcr.io/opendingux/retro-toolchain/buildroot}"
AUTO_BUILD_IMAGE=1

while [[ $# -gt 0 ]]; do
	case "$1" in
		--engine)
			ENGINE="${2:-}"
			shift 2
			;;
		--image)
			IMAGE="${2:-}"
			shift 2
			;;
		--skip-image-build)
			AUTO_BUILD_IMAGE=0
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			break
			;;
	esac
done

CONFIG="${CONFIG:-}"

if [[ $# -gt 0 ]]; then
	case "$1" in
		gcw0|rs90|lepus|installer)
			if [[ -n "${CONFIG}" && "${CONFIG}" != "$1" ]]; then
				echo "Conflicting build config values: CONFIG='${CONFIG}' and positional '$1'." >&2
				exit 1
			fi
			CONFIG="$1"
			shift
			;;
	esac
fi

if [[ -z "${CONFIG}" ]]; then
	echo "\$CONFIG not set. Please set it to the variant to build." >&2
	echo "Valid values are: gcw0, rs90, lepus, installer" >&2
	exit 1
fi

case "${CONFIG}" in
	gcw0|rs90|lepus|installer)
		;;
	*)
		echo "Invalid config: ${CONFIG}" >&2
		echo "Valid values are: gcw0, rs90, lepus, installer" >&2
		exit 1
		;;
esac

if [[ -z "${ENGINE}" ]]; then
	if command -v podman >/dev/null 2>&1; then
		ENGINE=podman
	elif command -v docker >/dev/null 2>&1; then
		ENGINE=docker
	else
		echo "Neither podman nor docker was found in PATH." >&2
		exit 1
	fi
fi

if [[ "${ENGINE}" != "docker" && "${ENGINE}" != "podman" ]]; then
	echo "--engine must be either 'docker' or 'podman'." >&2
	exit 1
fi

if ! command -v "${ENGINE}" >/dev/null 2>&1; then
	echo "Container engine '${ENGINE}' is not available in PATH." >&2
	exit 1
fi

if [[ ! -f "${DOCKERFILE_DIR}/Dockerfile" ]]; then
	echo "Missing Dockerfile at ${DOCKERFILE_DIR}/Dockerfile" >&2
	exit 1
fi

if [[ "${AUTO_BUILD_IMAGE}" -eq 1 ]] && ! "${ENGINE}" image inspect "${IMAGE}" >/dev/null 2>&1; then
	if [[ "${IMAGE}" = "opendingux-buildroot:local" ]]; then
		echo "Building container image '${IMAGE}' from support/docker/Dockerfile..."
		"${ENGINE}" build -t "${IMAGE}" "${DOCKERFILE_DIR}"
	else
		echo "Pulling container image '${IMAGE}'..."
		"${ENGINE}" pull "${IMAGE}"
	fi
fi

container_args=(
	run
	--rm
	-i
	--user "$(id -u):$(id -g)"
	--workdir "${REPO_DIR}"
	--mount "type=bind,src=${REPO_DIR},dst=${REPO_DIR}"
	--security-opt label=disable
)

if tty -s; then
	container_args+=( -t )
fi

for env_name in \
	all_proxy http_proxy https_proxy ftp_proxy no_proxy \
	ALL_PROXY HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY \
	BR2_DL_DIR BR2_CCACHE_DIR BR2_JLEVEL TOP_MAKE_COMMAND FORCE_UNSAFE_CONFIGURE; do
	if [[ -n "${!env_name:-}" ]]; then
		container_args+=( --env "${env_name}" )
	fi
done

container_cmd=(
	/bin/bash
	-lc
	'cd "$1"; shift; export CONFIG="$1"; shift; exec ./rebuild.sh "$@"'
	_
	"${REPO_DIR}"
	"${CONFIG}"
	"$@"
)

exec "${ENGINE}" "${container_args[@]}" "${IMAGE}" "${container_cmd[@]}"
