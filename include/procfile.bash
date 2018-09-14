
yaml-esque-keys() {
	declare desc="Get process type keys from colon-separated structure"
	while read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^#.* ]] && continue
		[[ "$line" == *:* ]] || continue
		key=${line%%:*}
		echo "$key"
	done <<< "$(cat)"
}

yaml-esque-get() {
	declare desc="Get key value from colon-separated structure"
	declare key="$1"
	local inputkey cmd
	while read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^#.* ]] && continue
		inputkey=${line%%:*}
		cmd=${line#*:}
		if [[ "$inputkey" == "$key" ]]; then
			echo "$cmd"
			break
		fi
	done <<< "$(cat)"
}

procfile-parse() {
	declare desc="Get command string for a process type from Procfile"
	declare type="$1"
	# app_path is defined in outer scope
	# shellcheck disable=SC2154
	cat "$app_path/Procfile" | yaml-esque-get "$type"
}

procfile-start() {
	declare desc="Run process type command from Procfile through exec"
	declare type="$1"
	local processcmd
	processcmd="$(procfile-parse "$type")"
	if [[ -z "$processcmd" ]]; then
		echo "Proc entrypoint ${type} does not exist. Please check your Procfile"
		exit 1
	else
		procfile-exec "$processcmd"
	fi
}

procfile-exec() {
	declare desc="Run command with a Heroku-like env"
	procfile-setup-home
	procfile-load-env
	procfile-load-profile
	cd "$app_path" || return 1
	exec $(eval echo "$@")
}

procfile-types() {
	title "Discovering process types"
	if [[ -f "$app_path/Procfile" ]]; then
		local types
		types="$(cat "$app_path/Procfile" | yaml-esque-keys | sort | uniq | xargs echo)"
		echo "Procfile declares types -> ${types// /, }"
		return
	fi
	if [[ -s "$app_path/.release" ]]; then
		local default_types
		default_types="$(cat "$app_path/.release" | yaml-keys default_process_types | xargs echo)"
		# selected_name is defined in outer scope
		# shellcheck disable=SC2154
		[[ "$default_types" ]] && \
			echo "Default types for $selected_name -> ${default_types// /, }"
		for type in $default_types; do
			echo "$type: $(cat "$app_path/.release" | yaml-get default_process_types "$type")" >> "$app_path/Procfile"
		done
		return
	fi
	echo "No process types found"
}

procfile-load-env() {
	local varname
	# env_path is defined in outer scope
	# shellcheck disable=SC2154
	if [[ -d "$env_path" ]]; then
		shopt -s nullglob
		for e in $env_path/*; do
			varname=$(basename "$e")
			export "$varname=$(cat "$e")"
		done
	fi
}

procfile-load-profile() {
	# export the current session, which includes custom evars
	# that were set when the container was started. - We don't
	# want the buildpack to bulldoze those.
	# (a few are ok to bulldoze though)
	env \
		| grep -Ev 'PATH|PS1|TERM|SELF|SHLVL|PWD' \
		| sed -e 's/^/export /;' \
		> /etc/default_profile.sh
	
	shopt -s nullglob
	for file in /etc/profile.d/*.sh; do
		# shellcheck disable=SC1090
		source "$file"
	done
	mkdir -p "$app_path/.profile.d"
	for file in $app_path/.profile.d/*.sh; do
		# shellcheck disable=SC1090
		source "$file"
	done
	
	# reset the default evars in case the buildpack bulldozed them
	source /etc/default_profile.sh
	
	shopt -u nullglob
	hash -r
}

procfile-setup-home() {
	export HOME="$app_path"
}
