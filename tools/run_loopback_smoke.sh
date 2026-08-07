#!/bin/bash

set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
server=${MACRDP_SERVER:-${1:-$repo_dir/build/macrdp-server}}
client=${MACRDP_LOOPBACK_CLIENT:-${2:-/tmp/macrdp-loopback-client}}
port=${MACRDP_LOOPBACK_PORT:-3390}
user=${MACRDP_LOOPBACK_USER:-Xian}
password=${MACRDP_LOOPBACK_PASSWORD:-LoopbackTest-2026}
network_profile=${MACRDP_LOOPBACK_NETWORK_PROFILE:-direct}
proxy=${MACRDP_LOOPBACK_PROXY:-/tmp/macrdp-loopback-proxy}
proxy_port=${MACRDP_LOOPBACK_PROXY_PORT:-3391}
keep_temp=${MACRDP_LOOPBACK_KEEP_TEMP:-0}
client_log_level=${MACRDP_LOOPBACK_CLIENT_LOG_LEVEL:-WARN}
clipboard_client_text=${MACRDP_LOOPBACK_CLIENT_CLIPBOARD_TEXT:-macrdp\ loopback\ client\ clipboard\ text}
clipboard_server_text=${MACRDP_LOOPBACK_SERVER_CLIPBOARD_TEXT:-macrdp\ loopback\ server\ clipboard\ text}

case "$network_profile" in
	direct)
		profile_gfx_min_frames=100
		profile_nogfx_min_frames=100
		profile_max_interval_ms=1000
		profile_first_frame_limit_ms=2000
		profile_duration_ms=10000
		profile_nogfx_duration_ms=10000
		profile_run_nogfx=1
		profile_delay_ms=0
		profile_jitter_ms=0
		profile_bandwidth_bps=0
		profile_outage_period_ms=0
		profile_outage_duration_ms=0
		profile_input_settle_seconds=1
		;;
	wan)
		profile_gfx_min_frames=100
		profile_nogfx_min_frames=1
		profile_max_interval_ms=5000
		profile_first_frame_limit_ms=10000
		profile_duration_ms=10000
		profile_nogfx_duration_ms=10000
		profile_run_nogfx=1
		profile_delay_ms=50
		profile_jitter_ms=10
		profile_bandwidth_bps=5000000
		profile_outage_period_ms=0
		profile_outage_duration_ms=0
		profile_input_settle_seconds=3
		;;
	wifi)
		profile_gfx_min_frames=50
		profile_nogfx_min_frames=1
		profile_max_interval_ms=10000
		profile_first_frame_limit_ms=15000
		profile_duration_ms=10000
		profile_nogfx_duration_ms=30000
		profile_run_nogfx=1
		profile_delay_ms=75
		profile_jitter_ms=40
		profile_bandwidth_bps=1000000
		profile_outage_period_ms=5000
		profile_outage_duration_ms=300
		profile_input_settle_seconds=4
		;;
	outage)
		profile_gfx_min_frames=50
		profile_nogfx_min_frames=1
		profile_max_interval_ms=10000
		profile_first_frame_limit_ms=15000
		profile_duration_ms=10000
		profile_nogfx_duration_ms=10000
		profile_run_nogfx=1
		profile_delay_ms=50
		profile_jitter_ms=50
		profile_bandwidth_bps=5000000
		profile_outage_period_ms=3000
		profile_outage_duration_ms=500
		profile_input_settle_seconds=4
		;;
	bad)
		profile_gfx_min_frames=1
		profile_nogfx_min_frames=0
		profile_max_interval_ms=30000
		profile_first_frame_limit_ms=30000
		profile_duration_ms=15000
		profile_nogfx_duration_ms=15000
		profile_run_nogfx=0
		profile_delay_ms=150
		profile_jitter_ms=100
		profile_bandwidth_bps=256000
		profile_outage_period_ms=4000
		profile_outage_duration_ms=1000
		profile_input_settle_seconds=6
		;;
	*)
		echo "unknown network profile: $network_profile (use direct, wan, wifi, outage, or bad)" >&2
		exit 2
		;;
esac

min_frames_override=${MACRDP_LOOPBACK_MIN_FRAMES:-}
gfx_min_frames=${MACRDP_LOOPBACK_GFX_MIN_FRAMES:-${min_frames_override:-$profile_gfx_min_frames}}
nogfx_min_frames=${MACRDP_LOOPBACK_NOGFX_MIN_FRAMES:-${min_frames_override:-$profile_nogfx_min_frames}}
max_interval_ms=${MACRDP_LOOPBACK_MAX_INTERVAL_MS:-$profile_max_interval_ms}
first_frame_limit_ms=${MACRDP_LOOPBACK_FIRST_FRAME_LIMIT_MS:-$profile_first_frame_limit_ms}
duration_ms=${MACRDP_LOOPBACK_DURATION_MS:-$profile_duration_ms}
nogfx_duration_ms=${MACRDP_LOOPBACK_NOGFX_DURATION_MS:-$profile_nogfx_duration_ms}
reconnect_duration_ms=${MACRDP_LOOPBACK_RECONNECT_DURATION_MS:-4000}
slow_client_duration_ms=${MACRDP_LOOPBACK_SLOW_CLIENT_DURATION_MS:-5000}
slow_client_event_delay_ms=${MACRDP_LOOPBACK_SLOW_CLIENT_EVENT_DELAY_MS:-250}
run_nogfx=${MACRDP_LOOPBACK_RUN_NOGFX:-$profile_run_nogfx}
input_settle_seconds=${MACRDP_LOOPBACK_INPUT_SETTLE_SECONDS:-$profile_input_settle_seconds}
proxy_delay_ms=${MACRDP_LOOPBACK_PROXY_DELAY_MS:-$profile_delay_ms}
proxy_jitter_ms=${MACRDP_LOOPBACK_PROXY_JITTER_MS:-$profile_jitter_ms}
proxy_bandwidth_bps=${MACRDP_LOOPBACK_PROXY_BANDWIDTH_BPS:-$profile_bandwidth_bps}
proxy_outage_period_ms=${MACRDP_LOOPBACK_PROXY_OUTAGE_PERIOD_MS:-$profile_outage_period_ms}
proxy_outage_duration_ms=${MACRDP_LOOPBACK_PROXY_OUTAGE_DURATION_MS:-$profile_outage_duration_ms}
proxy_options=(
	--delay-ms "$proxy_delay_ms"
	--jitter-ms "$proxy_jitter_ms"
	--bandwidth-bps "$proxy_bandwidth_bps"
	--outage-period-ms "$proxy_outage_period_ms"
	--outage-duration-ms "$proxy_outage_duration_ms"
	--seed 1
)

if [ ! -x "$server" ]; then
	echo "server executable not found or not executable: $server" >&2
	exit 2
fi
if [ ! -x "$client" ]; then
	echo "loopback client not found or not executable: $client" >&2
	echo "Set MACRDP_LOOPBACK_CLIENT to a FreeRDP-based loopback client." >&2
	exit 2
fi
if ! command -v nc >/dev/null 2>&1; then
	echo "nc is required to probe the local test listener" >&2
	exit 2
fi
if ! command -v pbcopy >/dev/null 2>&1; then
	echo "pbcopy is required for the clipboard loopback test" >&2
	exit 2
fi
if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
	echo "TCP port $port is already in use; choose MACRDP_LOOPBACK_PORT" >&2
	exit 2
fi
if [ "$network_profile" != "direct" ]; then
	if [ ! -x "$proxy" ]; then
		echo "loopback proxy not found or not executable: $proxy" >&2
		echo "Build it with tools/build_loopback_proxy.sh or set MACRDP_LOOPBACK_PROXY." >&2
		exit 2
	fi
	if [ "$proxy_port" = "$port" ]; then
		echo "proxy port must differ from server port" >&2
		exit 2
	fi
	if nc -z 127.0.0.1 "$proxy_port" >/dev/null 2>&1; then
		echo "TCP proxy port $proxy_port is already in use; choose MACRDP_LOOPBACK_PROXY_PORT" >&2
		exit 2
	fi
fi

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-loopback-smoke.XXXXXX")
server_pid=
proxy_pid=
client_port=$port
failed=0

stop_proxy() {
	if [ -n "${proxy_pid:-}" ]; then
		kill -TERM "$proxy_pid" >/dev/null 2>&1 || true
		wait "$proxy_pid" >/dev/null 2>&1 || true
		proxy_pid=
		client_port=$port
	fi
}

stop_server() {
	if [ -n "${server_pid:-}" ]; then
		kill -TERM "$server_pid" >/dev/null 2>&1 || true
		wait "$server_pid" >/dev/null 2>&1 || true
		server_pid=
	fi
}

cleanup() {
	stop_proxy
	stop_server
	if [ "$failed" -ne 0 ] || [ "$keep_temp" = "1" ]; then
		echo "loopback artifacts: $temp_dir" >&2
	else
		rm -rf "$temp_dir"
	fi
}
trap cleanup EXIT INT TERM

fail() {
	echo "FAIL: $*" >&2
	failed=1
}

wait_for_log() {
	log_file=$1
	pattern=$2
	for attempt in $(seq 1 100); do
		if grep -q "$pattern" "$log_file"; then
			return 0
		fi
		sleep 0.05
	done
	return 1
}

set_test_clipboard() {
	if ! printf '%s' "$clipboard_server_text" | pbcopy; then
		echo "could not set the macOS test pasteboard" >&2
		return 1
	fi
}

metric() {
	key=$1
	printf '%s\n' "$2" | awk -v key="$key" '{
		for (field_index = 1; field_index <= NF; field_index++) {
			if ($field_index ~ ("^" key "=")) {
				sub(/^([^=]+=)/, "", $field_index)
				print $field_index
				exit
			}
		}
	}'
}

metric_max() {
	key=$1
	printf '%s\n' "$2" | awk -v key="$key" '{
		for (field_index = 1; field_index <= NF; field_index++) {
			if ($field_index ~ ("^" key "=")) {
				value = $field_index
				sub(/^([^=]+=)/, "", value)
				if (!found || value + 0 > maximum)
					maximum = value + 0
				found = 1
			}
		}
	} END {
		if (found)
			print maximum
	}'
}

wait_for_server() {
	case_name=$1
	server_log=$2
	for attempt in $(seq 1 100); do
		if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
			return 0
		fi
		if ! kill -0 "$server_pid" >/dev/null 2>&1; then
			echo "$case_name server exited before becoming ready:" >&2
			tail -n 40 "$server_log" >&2
			return 1
		fi
		sleep 0.1
	done
	echo "$case_name server did not become ready:" >&2
	tail -n 40 "$server_log" >&2
	return 1
}

wait_for_proxy() {
	case_name=$1
	proxy_log=$2
	for attempt in $(seq 1 100); do
		if nc -z 127.0.0.1 "$proxy_port" >/dev/null 2>&1; then
			return 0
		fi
		if ! kill -0 "$proxy_pid" >/dev/null 2>&1; then
			echo "$case_name proxy exited before becoming ready:" >&2
			tail -n 40 "$proxy_log" >&2
			return 1
		fi
		sleep 0.1
	done
	echo "$case_name proxy did not become ready:" >&2
	tail -n 40 "$proxy_log" >&2
	return 1
}

start_proxy() {
	case_name=$1
	case_dir="$temp_dir/$case_name"
	proxy_log="$case_dir/proxy.log"

	"$proxy" \
		--listen-address 127.0.0.1 \
		--listen-port "$proxy_port" \
		--upstream-address 127.0.0.1 \
		--upstream-port "$port" \
		"${proxy_options[@]}" >"$proxy_log" 2>&1 &
	proxy_pid=$!
	if ! wait_for_proxy "$case_name" "$proxy_log"; then
		return 1
	fi
	client_port=$proxy_port
}

start_server() {
	case_name=$1
	case_dir="$temp_dir/$case_name"
	server_log="$case_dir/server.log"
	mkdir -p "$case_dir/config"
	if ! set_test_clipboard; then
		return 1
	fi

	if [ "$case_name" = "nogfx" ]; then
		MACRDP_PASSWORD="$password" "$server" \
			--port "$port" \
			--bind-address 127.0.0.1 \
			--no-gfx \
			--user "$user" \
			--config-dir "$case_dir/config" \
			--log-level DEBUG >"$server_log" 2>&1 &
	else
		MACRDP_PASSWORD="$password" "$server" \
			--port "$port" \
			--bind-address 127.0.0.1 \
			--user "$user" \
			--config-dir "$case_dir/config" \
			--log-level DEBUG >"$server_log" 2>&1 &
	fi
	server_pid=$!
	if ! wait_for_server "$case_name" "$server_log"; then
		return 1
	fi
	if [ "$network_profile" != "direct" ]; then
		start_proxy "$case_name"
	fi
}

run_client() {
	case_name=$1
	client_mode=${2:-$case_name}
	requested_width=${3:-}
	requested_height=${4:-}
	event_delay_ms=${5:-0}
	duration_override=${6:-$duration_ms}
	case_dir="$temp_dir/$case_name"
	mkdir -p "$case_dir"
	client_log="$case_dir/client.log"
	client_gfx=0
	client_command=(
		"$client"
		/v:127.0.0.1:"$client_port"
		/u:"$user"
		/p:"$password"
		/cert:ignore
		/log-level:"$client_log_level"
	)
	if [ "$client_mode" != "nogfx" ]; then
		client_gfx=1
		client_command+=(/gfx:AVC420)
	fi
	if [ -n "$requested_width" ] && [ -n "$requested_height" ]; then
		client_command+=(/w:"$requested_width" /h:"$requested_height")
	fi
	if ! set_test_clipboard; then
		fail "$case_name could not prepare the test pasteboard"
		return
	fi

	if MACRDP_LOOPBACK_DURATION_MS="$duration_override" \
		MACRDP_LOOPBACK_GFX="$client_gfx" \
		MACRDP_LOOPBACK_EVENT_DELAY_MS="$event_delay_ms" \
		MACRDP_LOOPBACK_CLIENT_CLIPBOARD_TEXT="$clipboard_client_text" \
		MACRDP_LOOPBACK_SERVER_CLIPBOARD_TEXT="$clipboard_server_text" \
		"${client_command[@]}" >"$client_log" 2>&1; then
		client_status=0
	else
		client_status=$?
	fi

	summary=$(sed -n 's/^loopback summary: //p' "$client_log" | tail -n 1)
	if [ "$client_status" -ne 0 ]; then
		fail "$case_name client exited with status $client_status"
	fi
	if [ -z "$summary" ]; then
		fail "$case_name client produced no loopback summary"
		return
	fi

	frames=$(metric frames "$summary")
	first_frame=$(metric first_frame_ms "$summary")
	max_interval=$(metric max_interval_ms "$summary")
	input_clicks=$(metric input_clicks_sent "$summary")
	input_synchronize=$(metric input_synchronize_events_sent "$summary")
	input_keyboard=$(metric input_keyboard_events_sent "$summary")
	input_unicode=$(metric input_unicode_events_sent "$summary")
	input_wheel=$(metric input_wheel_events_sent "$summary")
	input_right_button=$(metric input_right_button_events_sent "$summary")
	input_middle_button=$(metric input_middle_button_events_sent "$summary")
	input_extended_mouse=$(metric input_extended_mouse_events_sent "$summary")
	input_drag=$(metric input_drag_events_sent "$summary")
	input_failures=$(metric input_send_failures "$summary")
	clipboard_server_lists=$(metric clipboard_server_format_lists_received "$summary")
	clipboard_server_list_responses=$(metric clipboard_server_format_list_responses_sent "$summary")
	clipboard_server_requests=$(metric clipboard_server_data_requests_sent "$summary")
	clipboard_server_responses=$(metric clipboard_server_data_responses_received "$summary")
	clipboard_client_lists=$(metric clipboard_client_format_lists_sent "$summary")
	clipboard_client_list_responses=$(metric clipboard_client_format_list_responses_received "$summary")
	clipboard_client_requests=$(metric clipboard_client_data_requests_received "$summary")
	clipboard_client_responses=$(metric clipboard_client_data_responses_sent "$summary")
	clipboard_matches=$(metric clipboard_matches "$summary")
	clipboard_failures=$(metric clipboard_failures "$summary")
	gfx_frames=$(metric gfx_frames "$summary")
	gfx_wire=$(metric gfx_wire_commands "$summary")
	gfx_avc420=$(metric gfx_avc420 "$summary")
	case_min_frames=$gfx_min_frames
	allow_slow=0
	case "$client_mode" in
		nogfx)
			case_min_frames=$nogfx_min_frames
			;;
		slow)
			case_min_frames=1
			allow_slow=1
			;;
		resize|reconnect)
			case_min_frames=1
			;;
	esac

	echo "$case_name: $summary"

	if [ "${frames:-0}" -lt "$case_min_frames" ]; then
		fail "$case_name received too few frames: ${frames:-0} < $case_min_frames"
	fi
	if [ "$case_min_frames" -gt 0 ]; then
		if [ "${first_frame:-0}" -le 0 ] || [ "$first_frame" -gt "$first_frame_limit_ms" ]; then
			fail "$case_name first frame latency is ${first_frame:-missing} ms"
		fi
	fi
	if [ "$allow_slow" = "0" ] && [ "${max_interval:-0}" -gt "$max_interval_ms" ]; then
		fail "$case_name max frame interval is ${max_interval} ms > $max_interval_ms ms"
	elif [ "$allow_slow" = "1" ]; then
		echo "$case_name: slow-client max frame interval=${max_interval}ms"
	fi
	if [ "${input_clicks:-0}" -lt 1 ]; then
		fail "$case_name sent no mouse click"
	fi
	if [ "${input_failures:-0}" -ne 0 ]; then
		fail "$case_name had $input_failures client-side input send failures"
	fi
	if [ "${clipboard_server_lists:-0}" -lt 1 ] \
		|| [ "${clipboard_server_list_responses:-0}" -lt 1 ] \
		|| [ "${clipboard_server_requests:-0}" -lt 1 ] \
		|| [ "${clipboard_server_responses:-0}" -lt 1 ] \
		|| [ "${clipboard_matches:-0}" -lt 1 ]; then
		fail "$case_name did not complete server-to-client clipboard verification"
	fi
	if [ "${clipboard_client_lists:-0}" -lt 1 ] \
		|| [ "${clipboard_client_list_responses:-0}" -lt 1 ] \
		|| [ "${clipboard_client_requests:-0}" -lt 1 ] \
		|| [ "${clipboard_client_responses:-0}" -lt 1 ]; then
		fail "$case_name did not complete client-to-server clipboard verification"
	fi
	if [ "${clipboard_failures:-0}" -ne 0 ]; then
		fail "$case_name had $clipboard_failures clipboard verification failures"
	fi
	server_case=$case_name
	if [ "$server_case" != "gfx" ] && [ "$server_case" != "nogfx" ]; then
		server_case=gfx
	fi
	server_log="$temp_dir/$server_case/server.log"
	if ! wait_for_log "$server_log" 'Received client clipboard data:'; then
		fail "$case_name server did not receive client clipboard data"
	fi
	if ! wait_for_log "$server_log" 'Frame pipeline:'; then
		fail "$case_name server produced no frame pipeline diagnostics"
	fi
	if grep -q 'Slow frame update\|Slow client frame handling' "$server_log"; then
		if [ "$allow_slow" = "1" ]; then
			echo "$case_name: expected slow client stages observed"
		elif [ "$network_profile" = "direct" ]; then
			fail "$case_name server reported a slow frame stage"
		else
			echo "$case_name: slow frame stages observed under network profile $network_profile"
		fi
	fi
	if ! wait_for_log "$server_log" 'shadow_input_mouse_event'; then
		fail "$case_name server did not receive a mouse event"
	fi

	if [ "$client_gfx" = "1" ]; then
		if [ "${gfx_frames:-0}" -lt 1 ] || [ "${gfx_wire:-0}" -lt 1 ]; then
			fail "$case_name client received no RDPGFX surface frames"
		fi
		if [ "${gfx_avc420:-0}" -lt 1 ]; then
			fail "$case_name client did not receive AVC420 frames"
		fi
	else
		if [ "${gfx_frames:-0}" -ne 0 ] || [ "${gfx_wire:-0}" -ne 0 ]; then
			fail "$case_name client unexpectedly received RDPGFX frames"
		fi
	fi
}

check_reconnect_and_resize() {
	server_log="$temp_dir/gfx/server.log"
	if ! grep -q 'shadow_client_post_connect.*activated (1280x720@32)' "$server_log"; then
		fail "reconnect resize test did not observe the 1280x720 connection"
	fi
	if ! grep -q 'shadow_client_post_connect.*activated (1024x768@32)' "$server_log"; then
		fail "reconnect resize test did not observe the 1024x768 connection"
	fi
	activated_count=$(grep -c 'shadow_client_post_connect.*activated (' "$server_log" || true)
	if [ "${activated_count:-0}" -lt 3 ]; then
		fail "reconnect test observed only $activated_count activated connections"
	fi
}

check_slow_client() {
	server_log="$temp_dir/gfx/server.log"
	if [ "${frames:-0}" -lt 2 ]; then
		fail "slow-client test observed too few frames to measure pacing"
	fi
	if [ "$slow_client_event_delay_ms" -gt 0 ] \
		&& [ "${max_interval:-0}" -lt "$slow_client_event_delay_ms" ]; then
		fail "slow-client max frame interval ${max_interval:-0}ms did not reflect the configured ${slow_client_event_delay_ms}ms event delay"
	fi
	if grep -q 'Slow client frame handling\|Frame barrier event\|Slow frame update' "$server_log"; then
		echo "slow-client: server slow-stage diagnostics observed"
	else
		echo "slow-client: no server slow-stage warning; client pacing metrics are the primary result"
	fi
}

check_input_pipeline() {
	case_name=$1
	case_dir="$temp_dir/$case_name"
	server_log="$case_dir/server.log"
	input_pipeline=$(grep 'Input pipeline:' "$server_log")
	if [ -z "$input_pipeline" ]; then
		fail "$case_name server produced no input pipeline diagnostics"
		return
	fi

	server_synchronize=$(metric_max synchronize "$input_pipeline")
	server_keyboard=$(metric_max keyboard "$input_pipeline")
	server_unicode=$(metric_max unicode "$input_pipeline")
	server_wheel=$(metric_max wheel "$input_pipeline")
	server_failures=$(metric_max injection_failures "$input_pipeline")
	if [ "${input_synchronize:-0}" -lt 1 ] || [ "${server_synchronize:-0}" -lt 1 ]; then
		fail "$case_name synchronize input did not reach the server"
	fi
	if [ "${input_keyboard:-0}" -lt 2 ] || [ "${server_keyboard:-0}" -lt 2 ]; then
		fail "$case_name keyboard input did not reach the server"
	fi
	if [ "${input_unicode:-0}" -lt 2 ] || [ "${server_unicode:-0}" -lt 2 ]; then
		fail "$case_name Unicode input did not reach the server"
	fi
	if [ "${input_wheel:-0}" -lt 4 ] || [ "${server_wheel:-0}" -lt 4 ]; then
		fail "$case_name vertical/horizontal wheel input did not reach the server"
	fi
	server_right_button=$(metric_max right_button "$input_pipeline")
	server_middle_button=$(metric_max middle_button "$input_pipeline")
	server_drag=$(metric_max drag "$input_pipeline")
	server_extended_mouse=$(metric_max extended_mouse "$input_pipeline")
	if [ "${input_right_button:-0}" -lt 2 ] || [ "${server_right_button:-0}" -lt 2 ]; then
		fail "$case_name right-button input did not reach the server"
	fi
	if [ "${input_middle_button:-0}" -lt 2 ] || [ "${server_middle_button:-0}" -lt 2 ]; then
		fail "$case_name middle-button input did not reach the server"
	fi
	if [ "${input_extended_mouse:-0}" -lt 4 ] || [ "${server_extended_mouse:-0}" -lt 4 ]; then
		fail "$case_name extended mouse input did not reach the server"
	fi
	if [ "${input_drag:-0}" -lt 1 ] || [ "${server_drag:-0}" -lt 1 ]; then
		fail "$case_name drag input did not reach the server"
	fi
	if [ "${server_failures:-0}" -ne 0 ]; then
		fail "$case_name server reported $server_failures input injection failures"
	fi
}

run_bad_password() {
	case_dir="$temp_dir/gfx"
	client_log="$case_dir/bad-password.log"
	if MACRDP_LOOPBACK_DURATION_MS=2000 \
	MACRDP_LOOPBACK_GFX=1 \
		"$client" \
			/v:127.0.0.1:"$client_port" \
			/u:"$user" \
			/p:DefinitelyWrongPassword \
			/cert:ignore \
			/log-level:WARN \
			/gfx:AVC420 >"$client_log" 2>&1; then
		fail "wrong-password client unexpectedly connected"
	fi
	if ! grep -q 'authentication failure\|nla_server_recv_stream\|Connection reset' "$case_dir/server.log"; then
		fail "server did not record the expected NLA failure"
	fi
}

echo "loopback smoke test: server=$server client=$client profile=$network_profile "\
	"duration=${duration_ms}ms delay=${proxy_delay_ms}ms jitter=${proxy_jitter_ms}ms "\
	"bandwidth=${proxy_bandwidth_bps}bps outage=${proxy_outage_period_ms}/${proxy_outage_duration_ms}ms "\
	"nogfx_duration=${nogfx_duration_ms}ms"

if start_server gfx; then
	run_client gfx
	if [ "$network_profile" = "direct" ]; then
		run_client reconnect-first resize 1280 720 0 "$reconnect_duration_ms"
		run_client reconnect-second resize 1024 768 0 "$reconnect_duration_ms"
		check_reconnect_and_resize
		run_client slow-client slow "" "" "$slow_client_event_delay_ms" "$slow_client_duration_ms"
		check_slow_client
	fi
	sleep "$input_settle_seconds"
	run_bad_password
else
	fail "could not start gfx server"
fi
stop_proxy
stop_server
check_input_pipeline gfx

if [ "$run_nogfx" = "1" ]; then
	if start_server nogfx; then
		run_client nogfx nogfx "" "" 0 "$nogfx_duration_ms"
		sleep "$input_settle_seconds"
	else
		fail "could not start nogfx server"
	fi
else
	echo "nogfx: skipped for network profile $network_profile (classic full-screen updates exceed the stress-test window)"
fi
stop_proxy
stop_server
if [ "$run_nogfx" = "1" ]; then
	check_input_pipeline nogfx
fi

if [ "$failed" -ne 0 ]; then
	exit 1
fi

echo "loopback smoke test: PASS"
