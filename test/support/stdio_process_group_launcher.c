#include <errno.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
  /* Match Harness's launcher shape: four host-owned identity arguments,
     followed by the original executable and its arguments. */
  if (argc < 6) return 64;

  if (setpgid(0, 0) != 0 && errno != EACCES) {
    if (errno != EPERM || getpgrp() != getpid()) {
      perror("setpgid");
      return 70;
    }
  }

  execv(argv[5], &argv[5]);
  perror("execv");
  return 71;
}
