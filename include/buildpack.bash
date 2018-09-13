
_envfile-parse() {
    declare desc="Parse input into shell export commands"
    local key
    local value
    while read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^#.* ]] && continue
        [[ "$line" =~ ^$ ]] && continue
        key=${line%%=*}
        key=${key#*export }
        value="${line#*=}"
        case "$value" in
            \'*|\"*)
                value="${value}"
                ;;
            *)
                value=\""${value}"\"
                ;;
        esac
        echo "export ${key}=${value}"
    done <<< "$(cat)"
}

_select-buildpack() {
	if [[ -n "$BUILDPACK_URL" ]]; then
		title "Fetching custom buildpack"
		# buildpack_path defined in outer scope
		# shellcheck disable=SC2154
		selected_path="$buildpack_path/custom"
		rm -rf "$selected_path"

		IFS='#' read -r url commit <<< "$BUILDPACK_URL"
		buildpack-install "$url" "$commit" custom &> /dev/null
		# shellcheck disable=SC2154
		selected_name="$("$selected_path/bin/detect" "$app_path" || true)"
	else
		local buildpacks=($buildpack_path/*)
		local valid_buildpacks=()
		for buildpack in "${buildpacks[@]}"; do
			"$buildpack/bin/detect" "$app_path" &> /dev/null \
				&& valid_buildpacks+=("$buildpack")
		done
		if [[ ${#valid_buildpacks[@]} -gt 1 ]]; then
			title "Warning: Multiple default buildpacks reported the ability to handle this app. The first buildpack in the list below will be used."
			echo "Detected buildpacks: $(sed -e "s:/tmp/buildpacks/[0-9][0-9]_buildpack-::g" <<< "${valid_buildpacks[@]}")" | indent
		fi
		if [[ ${#valid_buildpacks[@]} -gt 0 ]]; then
			selected_path="${valid_buildpacks[0]}"
			selected_name=$("$selected_path/bin/detect" "$app_path")
		fi
	fi
	if [[ "$selected_path" ]] && [[ "$selected_name" ]]; then
		title "$selected_name app detected"
	else
		title "Unable to select a buildpack"
		exit 1
	fi
}

buildpack-build() {
	declare desc="Build an application using installed buildpacks"
	ensure-paths
	buildpack-setup > /dev/null
	buildpack-execute | indent
	procfile-types | indent
}

buildpack-install() {
	declare desc="Install buildpack from Git URL and optional committish"
	declare url="$1" commit="$2" name="$3"
	ensure-paths
	if [[ ! "$url" ]]; then
		asset-cat include/buildpacks.txt | while read -r name url commit; do
			buildpack-install "$url" "$commit" "$name"
		done
		return
	fi
	# buildpack_path is defined in outer scope
	# shellcheck disable=SC2154
	local target_path="$buildpack_path/${name:-$(basename "$url")}"
	if [[ "$(git ls-remote "$url" &> /dev/null; echo $?)" -eq 0 ]]; then
		if [[ "$commit" ]]; then
			if ! git clone --branch "$commit" --quiet --depth 1 "$url" "$target_path" &>/dev/null; then
				# if the shallow clone failed partway through, clean up and try a full clone
				rm -rf "$target_path"
				git clone "$url" "$target_path"
				cd "$target_path" || return 1
				git checkout --quiet "$commit"
				cd - > /dev/null || return 1
			else
				echo "Cloning into '$target_path'..."
			fi
		else
			git clone --depth=1 "$url" "$target_path"
		fi
	else
		local tar_args
		case "$url" in
			*.tgz|*.tar.gz)
				target_path="${target_path//.tgz}"
				target_path="${target_path//.tar.gz}"
				tar_args="-xzC"
			;;
			*.tbz|*.tar.bz)
				target_path="${target_path//.tbz}"
				target_path="${target_path//.tar.bz}"
				tar_args="-xjC"
			;;
			*.tar)
				target_path="${target_path//.tar}"
				tar_args="-xC"
			;;
		esac
		echo "Downloading '$url' into '$target_path'..."
		mkdir -p "$target_path"
		curl -s --retry 2 "$url" | tar "$tar_args" "$target_path"
		chown -R root:root "$target_path"
		chmod 755 "$target_path"
	fi
}

buildpack-list() {
	declare desc="List installed buildpacks"
	ensure-paths
	ls -1 "$buildpack_path"
}

buildpack-setup() {
	# Buildpack expectations
	# app_path defined in outer scope
	# shellcheck disable=SC2154
	export APP_DIR="$app_path"
	# shellcheck disable=SC2154
	export HOME="$app_path"
	export REQUEST_ID="build-$RANDOM"
	export STACK="${STACK:-heroku-16}"
	# shellcheck disable=SC2154

	# Useful settings / features
	export CURL_CONNECT_TIMEOUT="30"
	export CURL_TIMEOUT="180"

	# Buildstep backwards compatibility
	if [[ -f "$app_path/.env" ]]; then
		# shellcheck disable=SC2046
		eval $(cat "$app_path/.env" | _envfile-parse)
	fi
}

buildpack-execute() {
	_select-buildpack
	cd "$app_path" || return 1
	"$selected_path/bin/compile" "$app_path" "$cache_path" "$env_path"
	if [[ -f "$selected_path/bin/release" ]]; then
		"$selected_path/bin/release" "$app_path" "$cache_path" > "$app_path/.release"
	fi
	if [[ -f "$app_path/.release" ]]; then
		config_vars="$(cat "$app_path/.release" | yaml-get config_vars)"
		if [[ "$config_vars" ]]; then
			mkdir -p "$app_path/.profile.d"
			OIFS=$IFS
			IFS=$'\n'
			for var in $config_vars; do
				echo "export $(echo "$var" | sed -e 's/=/="/' -e 's/$/"/')" >> "$app_path/.profile.d/00_config_vars.sh"
			done
			IFS=$OIFS
		fi
	fi
	cd - > /dev/null || return 1
}

buildpack-test() {
	declare desc="Build and run tests for an application using installed buildpacks"
	ensure-paths
	buildpack-setup > /dev/null
	_select-buildpack

	if [[ ! -f "$selected_path/bin/test-compile" ]] || [[ ! -f "$selected_path/bin/test" ]]; then
		echo "Selected buildpack does not support test feature"
		exit 1
	fi

	cd "$app_path" || return 1
	chmod 755 "$selected_path/bin/test-compile"
	"$selected_path/bin/test-compile" "$app_path" "$cache_path" "$env_path"

	cd "$app_path" || return 1
	procfile-load-profile
	chmod 755 "$selected_path/bin/test"
	"$selected_path/bin/test" "$app_path" "$env_path"
}
