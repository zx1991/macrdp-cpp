#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define LOOPBACK_PROXY_BUFFER_SIZE 262144

typedef struct
{
	uint64_t delay_us;
	uint64_t jitter_us;
	uint64_t bandwidth_bps;
	uint64_t outage_period_us;
	uint64_t outage_duration_us;
	uint64_t seed;
} shape_config;

typedef struct
{
	int source_fd;
	int destination_fd;
	shape_config shape;
	uint64_t start_us;
	uint64_t bytes_forwarded;
} relay_direction;

static volatile sig_atomic_t stop_requested = 0;

static void handle_signal(int signal_number)
{
	(void)signal_number;
	stop_requested = 1;
}

static uint64_t monotonic_us(void)
{
	struct timespec timestamp = { 0 };

	if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0)
		return 0;
	return (uint64_t)timestamp.tv_sec * UINT64_C(1000000)
	    + (uint64_t)timestamp.tv_nsec / UINT64_C(1000);
}

static void sleep_us(uint64_t duration_us)
{
	struct timespec request = {
		.tv_sec = (time_t)(duration_us / UINT64_C(1000000)),
		.tv_nsec = (long)((duration_us % UINT64_C(1000000)) * UINT64_C(1000)),
	};

	while (!stop_requested && nanosleep(&request, &request) != 0 && errno == EINTR)
	{
	}
}

static uint64_t next_random(uint64_t* state)
{
	uint64_t value = *state;

	if (value == 0)
		value = UINT64_C(0x9e3779b97f4a7c15);
	value ^= value << 13;
	value ^= value >> 7;
	value ^= value << 17;
	*state = value;
	return value;
}

static uint64_t shaped_delay_us(shape_config* shape)
{
	uint64_t jitter = 0;

	if (shape->jitter_us == 0)
		return shape->delay_us;

	jitter = next_random(&shape->seed) % (shape->jitter_us * 2 + 1);
	if (jitter <= shape->jitter_us)
	{
		const uint64_t reduction = shape->jitter_us - jitter;
		return shape->delay_us > reduction ? shape->delay_us - reduction : 0;
	}
	return shape->delay_us + (jitter - shape->jitter_us);
}

static void wait_for_outage(const shape_config* shape, uint64_t start_us)
{
	while (!stop_requested && shape->outage_period_us != 0)
	{
		const uint64_t now = monotonic_us();
		const uint64_t elapsed = now >= start_us ? now - start_us : 0;
		const uint64_t phase = elapsed % shape->outage_period_us;

		if (phase >= shape->outage_duration_us)
			return;

		const uint64_t remaining = shape->outage_duration_us - phase;
		sleep_us(remaining > UINT64_C(10000) ? UINT64_C(10000) : remaining);
	}
}

static int send_shaped(
	relay_direction* direction,
	const uint8_t* buffer,
	size_t size)
{
	size_t offset = 0;

	while (offset < size && !stop_requested)
	{
		const size_t chunk_size = size - offset > 16384 ? 16384 : size - offset;
		if (direction->shape.outage_period_us != 0)
			wait_for_outage(&direction->shape, direction->start_us);
		if (direction->shape.bandwidth_bps != 0)
		{
			const uint64_t transmit_us = (uint64_t)chunk_size * UINT64_C(8000000)
			    / direction->shape.bandwidth_bps;
			sleep_us(transmit_us);
		}

		const ssize_t sent = send(
			direction->destination_fd,
			buffer + offset,
			chunk_size,
			0);
		if (sent > 0)
		{
			offset += (size_t)sent;
			continue;
		}
		if (sent < 0 && errno == EINTR)
			continue;
		return -1;
	}
	return offset == size ? 0 : -1;
}

static ssize_t receive_burst(int descriptor, uint8_t* buffer, size_t capacity)
{
	ssize_t received = recv(descriptor, buffer, capacity, 0);
	if (received <= 0)
		return received;

	while ((size_t)received < capacity)
	{
		const ssize_t additional = recv(
			descriptor,
			buffer + received,
			capacity - (size_t)received,
			MSG_DONTWAIT);
		if (additional > 0)
		{
			received += additional;
			continue;
		}
		if (additional < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
			break;
		break;
	}
	return received;
}

static void* relay_direction_main(void* argument)
{
	relay_direction* direction = (relay_direction*)argument;
	uint8_t buffer[LOOPBACK_PROXY_BUFFER_SIZE];

	while (!stop_requested)
	{
		struct pollfd descriptor = {
			.fd = direction->source_fd,
			.events = POLLIN,
		};
		const int poll_status = poll(&descriptor, 1, 200);
		if (poll_status < 0)
		{
			if (errno == EINTR)
				continue;
			break;
		}
		if (poll_status == 0)
			continue;
		if ((descriptor.revents & (POLLIN | POLLHUP | POLLERR)) == 0)
			continue;

		const ssize_t received = receive_burst(direction->source_fd, buffer, sizeof(buffer));
		if (received == 0)
			break;
		if (received < 0)
		{
			if (errno == EINTR)
				continue;
			break;
		}

		/* Apply propagation delay once per locally observed burst. The payload is
		 * then paced in smaller writes so a large RDP PDU is not delayed once per
		 * arbitrary TCP read boundary. */
		sleep_us(shaped_delay_us(&direction->shape));
		wait_for_outage(&direction->shape, direction->start_us);
		if (send_shaped(direction, buffer, (size_t)received) != 0)
			break;
		direction->bytes_forwarded += (uint64_t)received;
	}

	(void)shutdown(direction->destination_fd, SHUT_WR);
	return NULL;
}

static int parse_uint64(const char* text, uint64_t* value)
{
	char* end = NULL;
	unsigned long long parsed = 0;

	if (text == NULL || *text == '\0')
		return -1;
	parsed = strtoull(text, &end, 10);
	if (end == text || *end != '\0')
		return -1;
	*value = (uint64_t)parsed;
	return 0;
}

static int parse_port(const char* text, uint16_t* port)
{
	uint64_t value = 0;

	if (parse_uint64(text, &value) != 0 || value == 0 || value > UINT16_MAX)
		return -1;
	*port = (uint16_t)value;
	return 0;
}

static void print_usage(const char* program)
{
	fprintf(stderr,
	        "usage: %s --listen-port PORT --upstream-port PORT [options]\n"
	        "  --listen-address ADDRESS       Listen address (default: 127.0.0.1)\n"
	        "  --upstream-address ADDRESS     Server address (default: 127.0.0.1)\n"
	        "  --delay-ms N                   One-way base delay\n"
	        "  --jitter-ms N                  Symmetric random delay range\n"
	        "  --bandwidth-bps N              Per-direction byte rate, 0 means unlimited\n"
	        "  --outage-period-ms N           Period of a forwarding outage, 0 disables it\n"
	        "  --outage-duration-ms N         Duration of each forwarding outage\n"
	        "  --seed N                       Deterministic jitter seed\n"
	        "  --help                         Show this help\n",
	        program);
}

static int connect_to(const char* address, uint16_t port)
{
	struct sockaddr_in endpoint = { 0 };
	int descriptor = -1;

	descriptor = socket(AF_INET, SOCK_STREAM, 0);
	if (descriptor < 0)
		return -1;
	endpoint.sin_family = AF_INET;
	endpoint.sin_port = htons(port);
	if (inet_pton(AF_INET, address, &endpoint.sin_addr) != 1
	    || connect(descriptor, (struct sockaddr*)&endpoint, sizeof(endpoint)) != 0)
	{
		(void)close(descriptor);
		return -1;
	}
	return descriptor;
}

static int create_listener(const char* address, uint16_t port)
{
	struct sockaddr_in endpoint = { 0 };
	int descriptor = -1;
	int reuse_address = 1;

	descriptor = socket(AF_INET, SOCK_STREAM, 0);
	if (descriptor < 0)
		return -1;
	(void)setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse_address,
	                 sizeof(reuse_address));
	endpoint.sin_family = AF_INET;
	endpoint.sin_port = htons(port);
	if (inet_pton(AF_INET, address, &endpoint.sin_addr) != 1
	    || bind(descriptor, (struct sockaddr*)&endpoint, sizeof(endpoint)) != 0
	    || listen(descriptor, 4) != 0)
	{
		(void)close(descriptor);
		return -1;
	}
	return descriptor;
}

static void relay_connection(int client_fd, int upstream_fd, const shape_config* shape)
{
	relay_direction client_to_server = {
		.source_fd = client_fd,
		.destination_fd = upstream_fd,
		.shape = *shape,
		.start_us = monotonic_us(),
	};
	relay_direction server_to_client = {
		.source_fd = upstream_fd,
		.destination_fd = client_fd,
		.shape = *shape,
		.start_us = client_to_server.start_us,
	};
	pthread_t client_to_server_thread;
	pthread_t server_to_client_thread;
	int client_thread_started = 0;
	int server_thread_started = 0;

	if (pthread_create(&client_to_server_thread, NULL, relay_direction_main,
	                   &client_to_server) != 0)
	{
		(void)shutdown(client_fd, SHUT_RDWR);
		(void)shutdown(upstream_fd, SHUT_RDWR);
		(void)close(client_fd);
		(void)close(upstream_fd);
		return;
	}
	client_thread_started = 1;
	if (pthread_create(&server_to_client_thread, NULL, relay_direction_main,
	                   &server_to_client) != 0)
	{
		(void)shutdown(client_fd, SHUT_RDWR);
		(void)shutdown(upstream_fd, SHUT_RDWR);
		(void)pthread_join(client_to_server_thread, NULL);
		(void)close(client_fd);
		(void)close(upstream_fd);
		return;
	}
	server_thread_started = 1;

	if (client_thread_started)
		(void)pthread_join(client_to_server_thread, NULL);
	(void)shutdown(client_fd, SHUT_RDWR);
	(void)shutdown(upstream_fd, SHUT_RDWR);
	if (server_thread_started)
		(void)pthread_join(server_to_client_thread, NULL);
	(void)close(client_fd);
	(void)close(upstream_fd);
	fprintf(stderr, "connection closed: client_to_server=%llu bytes server_to_client=%llu bytes\n",
	        (unsigned long long)client_to_server.bytes_forwarded,
	        (unsigned long long)server_to_client.bytes_forwarded);
}

int main(int argc, char** argv)
{
	const char* listen_address = "127.0.0.1";
	const char* upstream_address = "127.0.0.1";
	uint16_t listen_port = 0;
	uint16_t upstream_port = 0;
	shape_config shape = {
		.seed = UINT64_C(0x4d595df4d0f33173),
	};
	int listener = -1;

	for (int index = 1; index < argc; index += 2)
	{
		const char* argument = argv[index];
		const char* value = index + 1 < argc ? argv[index + 1] : NULL;
		uint64_t parsed = 0;

		if (strcmp(argument, "--help") == 0)
		{
			print_usage(argv[0]);
			return 0;
		}
		if (value == NULL)
		{
			fprintf(stderr, "missing value for %s\n", argument);
			return 2;
		}
		if (strcmp(argument, "--listen-address") == 0)
			listen_address = value;
		else if (strcmp(argument, "--upstream-address") == 0)
			upstream_address = value;
		else if (strcmp(argument, "--listen-port") == 0)
		{
			if (parse_port(value, &listen_port) != 0)
				return 2;
		}
		else if (strcmp(argument, "--upstream-port") == 0)
		{
			if (parse_port(value, &upstream_port) != 0)
				return 2;
		}
		else if (strcmp(argument, "--delay-ms") == 0)
		{
			if (parse_uint64(value, &parsed) != 0 || parsed > UINT64_MAX / 1000)
				return 2;
			shape.delay_us = parsed * 1000;
		}
		else if (strcmp(argument, "--jitter-ms") == 0)
		{
			if (parse_uint64(value, &parsed) != 0 || parsed > UINT64_MAX / 1000)
				return 2;
			shape.jitter_us = parsed * 1000;
		}
		else if (strcmp(argument, "--bandwidth-bps") == 0)
		{
			if (parse_uint64(value, &shape.bandwidth_bps) != 0)
				return 2;
		}
		else if (strcmp(argument, "--outage-period-ms") == 0)
		{
			if (parse_uint64(value, &parsed) != 0 || parsed > UINT64_MAX / 1000)
				return 2;
			shape.outage_period_us = parsed * 1000;
		}
		else if (strcmp(argument, "--outage-duration-ms") == 0)
		{
			if (parse_uint64(value, &parsed) != 0 || parsed > UINT64_MAX / 1000)
				return 2;
			shape.outage_duration_us = parsed * 1000;
		}
		else if (strcmp(argument, "--seed") == 0)
		{
			if (parse_uint64(value, &shape.seed) != 0)
				return 2;
		}
		else
		{
			fprintf(stderr, "unknown option: %s\n", argument);
			print_usage(argv[0]);
			return 2;
		}
	}

	if (listen_port == 0 || upstream_port == 0)
	{
		fprintf(stderr, "--listen-port and --upstream-port are required\n");
		return 2;
	}
	if (shape.outage_duration_us > shape.outage_period_us && shape.outage_period_us != 0)
		shape.outage_duration_us = shape.outage_period_us;
	if (shape.seed == 0)
		shape.seed = UINT64_C(0x4d595df4d0f33173);

	(void)signal(SIGINT, handle_signal);
	(void)signal(SIGTERM, handle_signal);
	(void)signal(SIGPIPE, SIG_IGN);
	listener = create_listener(listen_address, listen_port);
	if (listener < 0)
	{
		fprintf(stderr, "unable to listen on %s:%u: %s\n", listen_address, listen_port,
		        strerror(errno));
		return 1;
	}
	fprintf(stderr,
	        "proxy listening on %s:%u -> %s:%u delay=%llums jitter=%llums bandwidth=%llubps "
	        "outage=%llums/%llums\n",
	        listen_address,
	        listen_port,
	        upstream_address,
		upstream_port,
	        (unsigned long long)(shape.delay_us / 1000),
	        (unsigned long long)(shape.jitter_us / 1000),
	        (unsigned long long)shape.bandwidth_bps,
	        (unsigned long long)(shape.outage_period_us / 1000),
	        (unsigned long long)(shape.outage_duration_us / 1000));

	while (!stop_requested)
	{
		struct pollfd descriptor = {
			.fd = listener,
			.events = POLLIN,
		};
		const int poll_status = poll(&descriptor, 1, 200);
		if (poll_status < 0)
		{
			if (errno == EINTR)
				continue;
			break;
		}
		if (poll_status == 0)
			continue;

		const int client_fd = accept(listener, NULL, NULL);
		if (client_fd < 0)
		{
			if (errno == EINTR)
				continue;
			break;
		}
		const int upstream_fd = connect_to(upstream_address, upstream_port);
		if (upstream_fd < 0)
		{
			(void)close(client_fd);
			continue;
		}
		relay_connection(client_fd, upstream_fd, &shape);
	}

	(void)close(listener);
	return 0;
}
