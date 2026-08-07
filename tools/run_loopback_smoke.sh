#!/bin/bash

set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
server=${MACRDP_SERVER:-$repo_dir/build/macrdp-server}
client=${MACRDP_LOOPBACK_CLIENT:-/tmp/macrdp-loopback-client}
port=${MACRDP_LOOPBACK_PORT:-3390}
user=${MACRDP_LOOPBACK_USER:-macrdp-test-user}
password=${MACRDP_LOOPBACK_PASSWORD:-macrdp-test-password}
network_profile=${MACRDP_LOOPBACK_NETWORK_PROFILE:-direct}
proxy=${MACRDP_LOOPBACK_PROXY:-/tmp/macrdp-loopback-proxy}
proxy_port=${MACRDP_LOOPBACK_PROXY_PORT:-3391}
keep_temp=${MACRDP_LOOPBACK_KEEP_TEMP:-0}
client_log_level=${MACRDP_LOOPBACK_CLIENT_LOG_LEVEL:-WARN}
server_log_level=${MACRDP_LOOPBACK_SERVER_LOG_LEVEL:-DEBUG}
server_bitrate=${MACRDP_LOOPBACK_SERVER_BITRATE:-}
server_fps=${MACRDP_LOOPBACK_SERVER_FPS:-}
gfx_codec=${MACRDP_LOOPBACK_GFX_CODEC:-AVC420}
synthetic_audio=${MACRDP_LOOPBACK_SYNTHETIC_AUDIO:-1}
disable_audio=${MACRDP_LOOPBACK_DISABLE_AUDIO:-0}
audio_format=${MACRDP_LOOPBACK_AUDIO_FORMAT:-auto}
expected_audio_format=${MACRDP_LOOPBACK_EXPECT_AUDIO_FORMAT:-auto}
clipboard_client_text=${MACRDP_LOOPBACK_CLIENT_CLIPBOARD_TEXT:-macrdp\ loopback\ client\ clipboard\ text}
clipboard_server_text=${MACRDP_LOOPBACK_SERVER_CLIPBOARD_TEXT:-macrdp\ loopback\ server\ clipboard\ text}
keyboard_probe=${MACRDP_LOOPBACK_PROBE_F:-0}
keyboard_probe_enabled=0
case "$keyboard_probe" in
	""|0|n|N) ;;
	*) keyboard_probe_enabled=1 ;;
esac

usage() {
	cat <<EOF
Usage: $0 [options] [SERVER [CLIENT]]

Options:
  --profile NAME  Use direct, wan, wifi, outage, or bad network shaping.
  --server PATH   Use this macrdp-server executable.
  --client PATH   Use this FreeRDP loopback client executable.
  --bitrate RATE  Pass --bitrate RATE to the server for reproducible tuning.
  --fps NUMBER    Pass --fps NUMBER to the server for reproducible tuning.
  --gfx-codec NAME  Use AVC420 or AVC444 for the GFX phase (default: AVC420).
  --audio-format FORMAT  Request a WAVE format tag, or auto-negotiate.
  --expect-audio-format FORMAT  Expect a WAVE format tag, or auto for compressed audio.
  --no-audio      Disable audio capture and RDPSND for this run.
  -h, --help      Show this help.

The positional SERVER and CLIENT form is retained for compatibility. The
MACRDP_* environment variables can configure the same values.
EOF
}

add_positional_argument() {
	positional_count=$((positional_count + 1))
	case "$positional_count" in
		1) server=$1 ;;
		2) client=$1 ;;
		*)
			echo "too many positional arguments" >&2
			usage >&2
			exit 2
			;;
	esac
}

positional_count=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--profile)
			if [ "$#" -lt 2 ]; then
				echo "--profile requires a value" >&2
				usage >&2
				exit 2
			fi
			network_profile=$2
			shift 2
			;;
		--profile=*)
			network_profile=${1#--profile=}
			shift
			;;
		--server)
			if [ "$#" -lt 2 ]; then
				echo "--server requires a value" >&2
				usage >&2
				exit 2
			fi
			server=$2
			shift 2
			;;
		--server=*)
			server=${1#--server=}
			shift
			;;
		--client)
			if [ "$#" -lt 2 ]; then
				echo "--client requires a value" >&2
				usage >&2
				exit 2
			fi
			client=$2
			shift 2
			;;
		--client=*)
			client=${1#--client=}
			shift
			;;
		--bitrate)
			if [ "$#" -lt 2 ]; then
				echo "--bitrate requires a value" >&2
				usage >&2
				exit 2
			fi
			server_bitrate=$2
			shift 2
			;;
		--bitrate=*)
			server_bitrate=${1#--bitrate=}
			shift
			;;
		--fps)
			if [ "$#" -lt 2 ]; then
				echo "--fps requires a value" >&2
				usage >&2
				exit 2
			fi
			server_fps=$2
			shift 2
			;;
		--fps=*)
			server_fps=${1#--fps=}
			shift
			;;
		--gfx-codec)
			if [ "$#" -lt 2 ]; then
				echo "--gfx-codec requires a value" >&2
				usage >&2
				exit 2
			fi
			gfx_codec=$2
			shift 2
			;;
		--gfx-codec=*)
			gfx_codec=${1#--gfx-codec=}
			shift
			;;
		--audio-format)
			if [ "$#" -lt 2 ]; then
				echo "--audio-format requires a value" >&2
				usage >&2
				exit 2
			fi
			audio_format=$2
			shift 2
			;;
		--audio-format=*)
			audio_format=${1#--audio-format=}
			shift
			;;
		--expect-audio-format)
			if [ "$#" -lt 2 ]; then
				echo "--expect-audio-format requires a value" >&2
				usage >&2
				exit 2
			fi
			expected_audio_format=$2
			shift 2
			;;
		--expect-audio-format=*)
			expected_audio_format=${1#--expect-audio-format=}
			shift
			;;
		--no-audio)
			disable_audio=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			while [ "$#" -gt 0 ]; do
				add_positional_argument "$1"
				shift
			done
			;;
		-*)
			echo "unknown option: $1" >&2
			usage >&2
			exit 2
			;;
		*)
			add_positional_argument "$1"
			shift
			;;
	esac
done

case "$gfx_codec" in
	AVC420|avc420)
		gfx_codec=AVC420
		;;
	AVC444|avc444)
		gfx_codec=AVC444
		;;
	*)
		echo "GFX codec must be AVC420 or AVC444" >&2
		exit 2
		;;
esac

audio_label=on
case "$disable_audio" in
	1|y|Y|yes|YES|true|TRUE)
		disable_audio=1
		audio_label=off
		;;
	0|n|N|no|NO|false|FALSE|'')
		disable_audio=0
		;;
	*)
		echo "MACRDP_LOOPBACK_DISABLE_AUDIO must be a boolean value" >&2
		exit 2
		;;
esac

expected_audio_format_auto=0
if [ "$expected_audio_format" = "auto" ] || [ "$expected_audio_format" = "AUTO" ]; then
	expected_audio_format_auto=1
	expected_audio_format_value=0
else
	if ! expected_audio_format_value=$((expected_audio_format)); then
		echo "MACRDP_LOOPBACK_EXPECT_AUDIO_FORMAT must be a numeric WAVE format tag or auto" >&2
		exit 2
	fi
fi

expected_audio_label=$expected_audio_format

if [ "$positional_count" -eq 1 ]; then
	case "$server" in
		direct|wan|wifi|outage|bad)
			echo "'$server' is a network profile, not a server path; use --profile $server" >&2
			exit 2
			;;
	esac
fi

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
		profile_clipboard_wait_seconds=5
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
		profile_clipboard_wait_seconds=10
		;;
	wifi)
		profile_gfx_min_frames=1
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
		profile_clipboard_wait_seconds=45
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
		profile_clipboard_wait_seconds=20
		;;
	bad)
		profile_gfx_min_frames=1
		profile_nogfx_min_frames=0
		profile_max_interval_ms=30000
		profile_first_frame_limit_ms=30000
		profile_duration_ms=30000
		profile_nogfx_duration_ms=15000
		profile_run_nogfx=0
		profile_delay_ms=150
		profile_jitter_ms=100
		profile_bandwidth_bps=256000
		profile_outage_period_ms=4000
		profile_outage_duration_ms=1000
		profile_input_settle_seconds=6
		profile_clipboard_wait_seconds=60
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
clipboard_wait_seconds=${MACRDP_LOOPBACK_CLIPBOARD_WAIT_SECONDS:-$profile_clipboard_wait_seconds}
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

case "$clipboard_wait_seconds" in
	''|*[!0-9]*)
		echo "MACRDP_LOOPBACK_CLIPBOARD_WAIT_SECONDS must be a non-negative integer" >&2
		exit 2
		;;
esac

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
	wait_seconds=${3:-5}
	if [ "$wait_seconds" -eq 0 ]; then
		return 1
	fi
	for attempt in $(seq 1 $((wait_seconds * 20))); do
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
	server_command=(
		"$server"
		--port "$port"
		--bind-address 127.0.0.1
		--user "$user"
		--config-dir "$case_dir/config"
		--log-level "$server_log_level"
	)
	if [ -n "$server_bitrate" ]; then
		server_command+=(--bitrate "$server_bitrate")
	fi
	if [ -n "$server_fps" ]; then
		server_command+=(--fps "$server_fps")
	fi
	if [ "$disable_audio" -eq 1 ]; then
		server_command+=(--no-audio)
	fi
	mkdir -p "$case_dir/config"
	if ! set_test_clipboard; then
		return 1
	fi

	if [ "$case_name" = "nogfx" ]; then
		server_command+=(--no-gfx)
	elif [ "$gfx_codec" = "AVC444" ]; then
		server_command+=(--avc444)
	fi
	MACRDP_AUDIO_TEST_TONE="$synthetic_audio" MACRDP_PASSWORD="$password" \
		"${server_command[@]}" >"$server_log" 2>&1 &
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
		client_command+=(/gfx:"$gfx_codec")
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
		MACRDP_LOOPBACK_GFX_CODEC="$gfx_codec" \
		MACRDP_LOOPBACK_AUDIO_FORMAT="$audio_format" \
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
	input_keyboard_repeats=$(metric input_keyboard_repeats_sent "$summary")
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
	audio_server_formats=$(metric audio_server_formats "$summary")
	audio_open_count=$(metric audio_open_count "$summary")
	audio_play_callbacks=$(metric audio_play_callbacks "$summary")
	audio_pcm_bytes=$(metric audio_pcm_bytes "$summary")
	audio_first_play=$(metric audio_first_play_ms "$summary")
	audio_max_interval=$(metric audio_max_interval_ms "$summary")
	audio_non_pcm=$(metric audio_non_pcm_callbacks "$summary")
	audio_format_tag=$(metric audio_format_tag "$summary")
	audio_channels=$(metric audio_channels "$summary")
	audio_sample_rate=$(metric audio_sample_rate "$summary")
	audio_bits=$(metric audio_bits_per_sample "$summary")
	gfx_frames=$(metric gfx_frames "$summary")
	gfx_max_interval=$(metric gfx_max_interval_ms "$summary")
	gfx_wire=$(metric gfx_wire_commands "$summary")
	gfx_avc420=$(metric gfx_avc420 "$summary")
	gfx_avc444=$(metric gfx_avc444 "$summary")
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
	if [ "${input_keyboard_repeats:-0}" -lt 2 ]; then
		fail "$case_name keyboard repeat probe did not send two repeated key-down events"
	fi
	if [ "$keyboard_probe_enabled" = "1" ] && [ "${input_keyboard:-0}" -lt 24 ]; then
		fail "$case_name keyboard probe did not send the expected F key pair"
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
	if [ "$disable_audio" = "1" ]; then
		if [ "${audio_open_count:-0}" -ne 0 ] \
			|| [ "${audio_play_callbacks:-0}" -ne 0 ] \
			|| [ "${audio_pcm_bytes:-0}" -ne 0 ] \
			|| [ "${audio_pcm_frames:-0}" -ne 0 ]; then
			fail "$case_name received audio even though audio capture is disabled"
		fi
	elif [ "$synthetic_audio" != "0" ]; then
		if [ "${audio_server_formats:-0}" -lt 1 ] \
			|| [ "${audio_open_count:-0}" -lt 1 ] \
			|| [ "${audio_play_callbacks:-0}" -lt 1 ] \
			|| [ "${audio_pcm_bytes:-0}" -le 0 ]; then
			fail "$case_name did not receive RDPSND audio"
		fi
		if [ "${audio_first_play:-0}" -le 0 ] || [ "${audio_first_play:-0}" -gt "$first_frame_limit_ms" ]; then
			fail "$case_name first audio callback latency is ${audio_first_play:-missing} ms"
		fi
		expected_non_pcm=0
		if [ "$expected_audio_format_value" -ne 1 ]; then
			expected_non_pcm=1
		fi
		if [ "$expected_non_pcm" -eq 0 ] && [ "${audio_non_pcm:-0}" -ne 0 ]; then
			fail "$case_name unexpectedly delivered a compressed audio callback"
		fi
		if [ "$expected_non_pcm" -eq 1 ] && [ "${audio_non_pcm:-0}" -lt 1 ]; then
			fail "$case_name did not deliver a compressed audio callback"
		fi
		if [ "$expected_audio_format_auto" -eq 0 ] \
			&& [ "${audio_format_tag:-0}" -ne "$expected_audio_format_value" ]; then
			fail "$case_name negotiated unexpected audio format: expected_tag=$expected_audio_format_value tag=${audio_format_tag:-missing}"
		fi
		if [ "${audio_channels:-0}" -ne 2 ] || [ "${audio_sample_rate:-0}" -ne 44100 ] \
			|| [ "${audio_bits:-0}" -ne 16 ]; then
			fail "$case_name negotiated unexpected audio format: expected_tag=$expected_audio_label tag=${audio_format_tag:-missing} channels=${audio_channels:-missing} rate=${audio_sample_rate:-missing} bits=${audio_bits:-missing} non_pcm=${audio_non_pcm:-missing}"
		fi
	fi
	server_case=$case_name
	if [ "$server_case" != "gfx" ] && [ "$server_case" != "nogfx" ]; then
		server_case=gfx
	fi
	server_log="$temp_dir/$server_case/server.log"
	if ! wait_for_log "$server_log" 'Received client clipboard data:' "$clipboard_wait_seconds"; then
		fail "$case_name server did not receive client clipboard data"
	fi
	if ! wait_for_log "$server_log" 'Frame pipeline:'; then
		fail "$case_name server produced no frame pipeline diagnostics"
	fi
	if grep -q 'Failed to drain FreeRDP output buffer' "$server_log"; then
		fail "$case_name server reported an unexplained output drain failure"
	fi
	output_diagnostics=$(grep 'Output pipeline: blocked=' "$server_log" || true)
	if [ -z "$output_diagnostics" ]; then
		fail "$case_name server produced no output queue diagnostics"
	else
		for output_metric in queue_depth queue_capacity queue_max \
			transport_queue_bytes transport_queue_max transport_queue_limit \
			video_deferred video_coalesced h264_deferred h264_output_deferred \
			audio_queued audio_dropped blocked_ms blocked_max_ms \
			blocked_events drain_attempts; do
			if [ -z "$(metric "$output_metric" "$output_diagnostics")" ]; then
				fail "$case_name output diagnostics did not report $output_metric"
			fi
		done
	fi
	output_pipeline=$(grep -E 'Output pipeline (blocked|recovered):' "$server_log" || true)
	if [ -n "$output_pipeline" ]; then
		echo "$case_name: output backpressure diagnostics observed"
		audio_dropped=$(metric_max audio_dropped "$output_pipeline")
		if [ "$disable_audio" = "0" ] && [ "$network_profile" != "direct" ] \
			&& [ "${audio_dropped:-0}" -lt 1 ]; then
			fail "$case_name output backpressure did not drop stale audio messages"
		fi
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
	if ! wait_for_log "$server_log" 'Input pipeline:'; then
		fail "$case_name server did not process input events"
	fi
	if [ "$keyboard_probe_enabled" = "1" ]; then
		if [ "$server_log_level" = "DEBUG" ]; then
			if ! grep -Eq 'post_keyboard_event.*code=0x21 keycode=3 action=down' "$server_log" \
				|| ! grep -Eq 'post_keyboard_event.*code=0x21 keycode=3 action=up' "$server_log"; then
				fail "$case_name server did not map the F probe to macOS keycode 3 down/up"
			fi
		else
			echo "$case_name: F mapping log check skipped because server log level is $server_log_level (use DEBUG for keycode verification)"
		fi
	fi

	if [ "$client_gfx" = "1" ]; then
		if [ "${gfx_frames:-0}" -lt 1 ] || [ "${gfx_wire:-0}" -lt 1 ]; then
			fail "$case_name client received no RDPGFX surface frames"
		fi
		if [ "$gfx_codec" = "AVC444" ]; then
			if [ "${gfx_avc444:-0}" -lt 1 ]; then
				fail "$case_name client did not receive AVC444 frames"
			fi
		elif [ "${gfx_avc420:-0}" -lt 1 ]; then
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
	slow_interval_ms=${max_interval:-0}
	if [ "${gfx_frames:-0}" -ge 2 ]; then
		slow_interval_ms=${gfx_max_interval:-$slow_interval_ms}
	fi
	if [ "$slow_client_event_delay_ms" -gt 0 ] \
		&& [ "$slow_interval_ms" -lt "$slow_client_event_delay_ms" ]; then
		fail "slow-client max frame interval ${slow_interval_ms}ms did not reflect the configured ${slow_client_event_delay_ms}ms event delay"
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
	server_keyboard_repeats=$(metric_max keyboard_repeats "$input_pipeline")
	server_keyboard_recoveries=$(metric_max keyboard_release_recoveries "$input_pipeline")
	server_unicode=$(metric_max unicode "$input_pipeline")
	server_wheel=$(metric_max wheel "$input_pipeline")
	server_failures=$(metric_max injection_failures "$input_pipeline")
	if [ "${input_synchronize:-0}" -lt 1 ] || [ "${server_synchronize:-0}" -lt 1 ]; then
		fail "$case_name synchronize input did not reach the server"
	fi
	if [ "${input_keyboard:-0}" -lt 2 ] || [ "${server_keyboard:-0}" -lt 2 ]; then
		fail "$case_name keyboard input did not reach the server"
	fi
	if [ "${input_keyboard_repeats:-0}" -lt 2 ] || [ "${server_keyboard_repeats:-0}" -lt 2 ]; then
		fail "$case_name keyboard repeat events did not reach the server"
	fi
	if [ "${server_keyboard_recoveries:-0}" -lt 1 ]; then
		fail "$case_name did not exercise keyboard release identity recovery"
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
		MACRDP_LOOPBACK_GFX_CODEC="$gfx_codec" \
		"$client" \
			/v:127.0.0.1:"$client_port" \
			/u:"$user" \
			/p:DefinitelyWrongPassword \
			/cert:ignore \
			/log-level:WARN \
			/gfx:"$gfx_codec" >"$client_log" 2>&1; then
		fail "wrong-password client unexpectedly connected"
	fi
	if ! grep -q 'authentication failure\|nla_server_recv_stream\|Connection reset' "$case_dir/server.log"; then
		fail "server did not record the expected NLA failure"
	fi
}

echo "loopback smoke test: server=$server client=$client profile=$network_profile "\
	"duration=${duration_ms}ms delay=${proxy_delay_ms}ms jitter=${proxy_jitter_ms}ms "\
	"bandwidth=${proxy_bandwidth_bps}bps outage=${proxy_outage_period_ms}/${proxy_outage_duration_ms}ms "\
	"bitrate=${server_bitrate:-default} fps=${server_fps:-default} gfx_codec=$gfx_codec "\
	"audio=$audio_label audio_format=$audio_format expected_audio_format=$expected_audio_label "\
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
