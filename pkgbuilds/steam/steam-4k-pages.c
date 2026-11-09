// Runs a command with 4K user pages on a 16K-page linux-aurora kernel.
//
// Valve's arm64 Steam binaries are linked with 4K segment alignment, so a
// 16K-page kernel (Apple Silicon) cannot exec them. linux-aurora booted with
// user4k=on lets a process ask for 4K pages for what it execs next. The
// preference is inherited across fork and exec, so steamwebhelper and the
// games Steam starts get 4K pages too. See the kernel's
// Documentation/arch/arm64/user4k.rst.

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

// Private prctl from linux-aurora, not assigned upstream.
#define PR_AURORA_SET_DEFAULT_PAGE_SIZE 0x41555003

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s COMMAND [ARGUMENTS...]\n", argv[0]);
		return 2;
	}

	if (prctl(PR_AURORA_SET_DEFAULT_PAGE_SIZE, 4096UL, 0UL, 0UL, 0UL)) {
		fprintf(stderr,
			"steam: this kernel uses %ld-byte pages and cannot give Steam 4K pages (%s).\n"
			"steam: boot linux-aurora with user4k=on, or start Steam in a VM with omarchy-launch-steam.\n",
			sysconf(_SC_PAGESIZE), strerror(errno));
		return 1;
	}

	execvp(argv[1], argv + 1);
	fprintf(stderr, "steam: cannot run %s: %s\n", argv[1], strerror(errno));
	return 127;
}
