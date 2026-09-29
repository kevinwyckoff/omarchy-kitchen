/* evwatch: print kernel uevents from hwmon and wake-ups of sysfs attributes
 * (poll POLLPRI), i.e. both halves of hwmon change notification. After a
 * uevent naming an attribute it reads that attribute, as a daemon would
 * ("read-after-uevent"); after a wake it reads the woken file ("poll-wake").
 * usage: evwatch <seconds> <attr>...   */
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static void rd(int fd, char *buf, size_t n) {
	ssize_t r = pread(fd, buf, n - 1, 0);
	buf[r > 0 ? r : 0] = 0;
	char *nl = strchr(buf, '\n'); if (nl) *nl = 0;
}

int main(int argc, char **argv) {
	int secs = atoi(argv[1]), n = argc - 2;
	struct pollfd pfd[64];
	char buf[8192];
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK, .nl_groups = 1 };
	int ns = socket(AF_NETLINK, SOCK_DGRAM, NETLINK_KOBJECT_UEVENT);
	if (ns < 0 || bind(ns, (struct sockaddr *)&sa, sizeof(sa)) < 0) { perror("netlink"); return 1; }
	pfd[0].fd = ns; pfd[0].events = POLLIN;
	for (int i = 0; i < n; i++) {
		pfd[i + 1].fd = open(argv[i + 2], O_RDONLY);
		if (pfd[i + 1].fd < 0) { perror(argv[i + 2]); return 1; }
		pfd[i + 1].events = POLLPRI | POLLERR;
		rd(pfd[i + 1].fd, buf, sizeof(buf));	/* arm */
		printf("watch %s = %s\n", argv[i + 2], buf);
	}
	fflush(stdout);
	double t0 = now(), end = t0 + secs;
	while (now() < end) {
		int r = poll(pfd, n + 1, (int)((end - now()) * 1000) + 1);
		if (r <= 0) continue;
		if (pfd[0].revents & POLLIN) {
			ssize_t l = recv(ns, buf, sizeof(buf) - 1, 0);
			if (l > 0) {
				buf[l] = 0;
				if (strstr(buf, "hwmon")) {
					char *dp = NULL, *nm = NULL;

					printf("[%7.3f] uevent %s", now() - t0, buf);
					for (char *p = buf + strlen(buf) + 1; p < buf + l; p += strlen(p) + 1) {
						if (!strncmp(p, "NAME=", 5) || !strncmp(p, "ACTION=", 7)) printf(" %s", p);
						if (!strncmp(p, "DEVPATH=", 8)) dp = p + 8;
						if (!strncmp(p, "NAME=", 5)) nm = p + 5;
					}
					printf("\n");
					if (dp && nm) {
						char path[512], v[64];
						int fd;

						snprintf(path, sizeof(path), "/sys%s/%s", dp, nm);
						fd = open(path, O_RDONLY);
						if (fd >= 0) {
							rd(fd, v, sizeof(v));
							close(fd);
							printf("[%7.3f] read-after-uevent %s = %s\n", now() - t0, nm, v);
						}
					}
				}
			}
		}
		for (int i = 0; i < n; i++)
			if (pfd[i + 1].revents & (POLLPRI | POLLERR)) {
				rd(pfd[i + 1].fd, buf, sizeof(buf));
				printf("[%7.3f] poll-wake %s = %s\n", now() - t0, argv[i + 2], buf);
			}
		fflush(stdout);
	}
	return 0;
}
