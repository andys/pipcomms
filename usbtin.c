#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <stdint.h>
#include <sys/time.h>
#include <sys/types.h>

int main(int argc, char *argv[])
{
  int fd, result, len, retries;
  unsigned char inbuf[256], outbuf[256];
  unsigned char *ch, cr = '\n';
  speed_t baud = B115200;

  if(argc != 2) {
    printf("ERROR: please supply serial port path (eg. /dev/ttyACM0) as argument\n");
    return 3;
  }

  fd = open(argv[1], O_RDWR | O_NONBLOCK | O_NOCTTY);
  if(fd < 1) {
    printf("failed to open\n");
    exit(1);
  }

  struct termios settings;
  tcgetattr(fd, &settings);

  cfsetospeed(&settings, baud); /* baud rate */
  settings.c_cflag &= ~PARENB; /* no parity */
  settings.c_cflag &= ~CSTOPB; /* 1 stop bit */
  settings.c_cflag &= ~CSIZE;
  settings.c_cflag |= CS8 | CLOCAL; /* 8 bits */
  settings.c_lflag = ICANON; /* canonical mode */
  settings.c_oflag &= ~OPOST; /* raw output */
  settings.c_cflag &= ~CRTSCTS;
  settings.c_cflag |= CREAD | CLOCAL;
  settings.c_lflag &= ~(ICANON | ECHO | ECHOE | ISIG);

  tcsetattr(fd, TCSANOW, &settings); /* apply the settings */
  tcflush(fd, TCOFLUSH);

  sprintf(outbuf, "C\r\n");
  len = strlen(outbuf);
  if (write(fd, outbuf, len) < len) {
      printf("failed to write (1)\n");
      exit(1);
  }

  usleep(100000);
  while(read(fd, inbuf, 1) > 0);

  
  sprintf(outbuf, "S6\r\n");
  len = strlen(outbuf);
  if (write(fd, outbuf, len) < len) {
      printf("failed to write (2)\n");
      exit(1);
  }
  usleep(100000);
  while(read(fd, inbuf, 1) > 0);

  sprintf(outbuf, "L\r\n");
  len = strlen(outbuf);
  if (write(fd, outbuf, len) < len) {
      printf("failed to write (3)\n");
      exit(1);
  }

  printf("Wrote the output OK, waiting for input...\n");
  while(1) {
    ch = inbuf;
    *ch = 0;

    result = read(fd, ch, 1);
    while(result == 1 && *ch != '\r' && *ch != 0x07) {
      fflush(stdout);

      ch++;
      *ch = 0;

      result = read(fd, ch, 1);
    }
    if(ch == inbuf) {
      usleep(10000);
    } else {
      printf("%s\n", inbuf);
      fflush(stdout);
    }
  }
  return 0;
}

