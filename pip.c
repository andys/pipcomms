#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <stdint.h>

#define INT16U uint16_t
#define INT8U uint8_t

INT16U cal_crc_half(INT8U *pin, INT8U len)
{
  INT16U crc;
  INT8U da;
  INT8U *ptr;
  INT8U bCRCHign;
  INT8U bCRCLow;
  INT16U crc_ta[16]=
  { 
    0x0000,0x1021,0x2042,0x3063,0x4084,0x50a5,0x60c6,0x70e7,
    0x8108,0x9129,0xa14a,0xb16b,0xc18c,0xd1ad,0xe1ce,0xf1ef
  };
  ptr=pin;
  crc=0;
  while(len--!=0) 
  {
    da=((INT8U)(crc>>8))>>4; 
    crc<<=4;
    crc^=crc_ta[da^(*ptr>>4)]; 
    da=((INT8U)(crc>>8))>>4; 
    crc<<=4;
    crc^=crc_ta[da^(*ptr&0x0f)]; 
    ptr++;
  }
  bCRCLow = crc;
  bCRCHign= (INT8U)(crc>>8);
  if(bCRCLow==0x28||bCRCLow==0x0d||bCRCLow==0x0a)
  {
       bCRCLow++;
  }
  if(bCRCHign==0x28||bCRCHign==0x0d||bCRCHign==0x0a)
  {
        bCRCHign++;
  }
  crc = ((INT16U)bCRCHign)<<8;
  crc += bCRCLow;
  return(crc);
}


int main(int argc, char *argv[])
{
  int fd, result, len;
  INT16U crc;
  char port[] = "/dev/ttyUSB0";
  unsigned char inbuf[256], outbuf[256];
  unsigned char *ch, cr = '\n';
  speed_t baud = B2400;
  fd = open(port, O_RDWR);

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
    crc = cal_crc_half((INT8U *) inbuf, (INT8U)strlen(inbuf));
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

    for(;;) {
      result = read(fd, ch, 1);
      if(result != 1) {
         printf("failed to read (1)\n");
         exit(1);
      }
      if(*ch == '\r' || *ch == '\n') {
        ch -= 2;
        *ch = 0;
        break;
      }
      ch++;
    }
    printf("%s\n", inbuf+1);
  }
  return 0;
}

