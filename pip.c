#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <stdint.h>
#include <sys/time.h>
#include <sys/types.h>

uint16_t cal_crc_half(uint8_t *pin, uint8_t len)
{
  uint16_t crc;
  uint8_t da;
  uint8_t *ptr;
  uint8_t bCRCHign;
  uint8_t bCRCLow;
  uint16_t crc_ta[16]=
  {
    0x0000,0x1021,0x2042,0x3063,0x4084,0x50a5,0x60c6,0x70e7,
    0x8108,0x9129,0xa14a,0xb16b,0xc18c,0xd1ad,0xe1ce,0xf1ef
  };
  ptr=pin;
  crc=0;
  while(len--!=0)
  {
    da=((uint8_t)(crc>>8))>>4;
    crc<<=4;
    crc^=crc_ta[da^(*ptr>>4)];
    da=((uint8_t)(crc>>8))>>4;
    crc<<=4;
    crc^=crc_ta[da^(*ptr&0x0f)];
    ptr++;
  }
  bCRCLow = crc;
  bCRCHign= (uint8_t)(crc>>8);
  if(bCRCLow==0x28||bCRCLow==0x0d||bCRCLow==0x0a)
  {
       bCRCLow++;
  }
  if(bCRCHign==0x28||bCRCHign==0x0d||bCRCHign==0x0a)
  {
        bCRCHign++;
  }
  crc = ((uint16_t)bCRCHign)<<8;
  crc += bCRCLow;
  return(crc);
}


int main(int argc, char *argv[])
{
  int fd, result, len, retries;
  uint16_t crc;
  char port[] = "/dev/ttyUSB0";
  unsigned char inbuf[256], outbuf[256];
  unsigned char *ch, cr = '\n';
  speed_t baud = B2400;
  /*fd_set listen_fds;
  struct timeval timeout;*/

  fd = open(port, O_RDWR | O_NONBLOCK);

  struct termios settings;
  tcgetattr(fd, &settings);

  cfsetospeed(&settings, baud); /* baud rate */
  settings.c_cflag &= ~PARENB; /* no parity */
  settings.c_cflag &= ~CSTOPB; /* 1 stop bit */
  settings.c_cflag &= ~CSIZE;
  settings.c_cflag |= CS8 | CLOCAL; /* 8 bits */
  settings.c_lflag = ICANON; /* canonical mode */
  settings.c_oflag &= ~OPOST; /* raw output */

  tcsetattr(fd, TCSANOW, &settings); /* apply the settings */
  tcflush(fd, TCOFLUSH);

  while(fgets(inbuf, 256 , stdin) != NULL) {
    inbuf[strcspn(inbuf, "\n")] = 0;
    crc = cal_crc_half((uint8_t *) inbuf, (uint8_t)strlen(inbuf));
    sprintf(outbuf, "%s%c%c\r", inbuf, 0xff & (crc >> 8), 0xff & crc);
    len = strlen(inbuf) + 3;

    /*printf("Writing '");
    for (int i = 0; i < len; i++) {
      if (i > 0) printf(":");
      printf("%02X", (unsigned char) outbuf[i]);
    }
    printf("'\n");*/

    if (write(fd, outbuf, len) < len) {
        printf("failed to write (1)\n");
        exit(1);
    }
    //printf("Wrote the output OK, waiting for input...\n");
    ch = inbuf;
    *ch = 0;

    for(retries = 0; 1; retries++) {
      usleep(100000);
      result = read(fd, inbuf, 255);
      if(result < 1) {
        if(retries >= 10) {
          if (write(fd, "\r", 1) != 1) {
            printf("failed to write (1)\n");
            exit(1);
          }
          retries = 0;
        }
      } else {
        ch = inbuf + result - 1;
        if(*ch == '\r' || *ch == '\n') {
          ch -= 2;
          if(ch >= inbuf) {
            *ch = 0;
            break;
          }
        }
      }
    }
    printf("%s\n", inbuf+1);
    fflush(stdout);
  }
  return 0;
}

