#include "PiezoCapture.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
int main(int argc,char**argv){
    if(argc!=2)return 1;
    int32_t error=0;PZCapture* capture=pz_capture_open((uint32_t)atoi(argv[1]),7,&error);
    if(!capture){printf("CoreAudio open error: %d\n",error);return 2;}
    float buffer[1024*7],peak[7]={0};unsigned long long received=0;
    double began=clock_gettime_nsec_np(CLOCK_MONOTONIC)/1e9;
    while(clock_gettime_nsec_np(CLOCK_MONOTONIC)/1e9-began<10){
        unsigned n=pz_capture_read(capture,buffer,1024);received+=n;
        for(unsigned i=0;i<n;++i)for(unsigned c=0;c<7;++c)peak[c]=fmaxf(peak[c],fabsf(buffer[i*7+c]));
        usleep(2000);
    }
    printf("{\"received\":%llu,\"captured\":%llu,\"dropped\":%llu,\"discontinuities\":%llu,\"bufferFrames\":%u,\"peaks\":[",received,pz_capture_total(capture),pz_capture_dropped(capture),pz_capture_discontinuities(capture),pz_capture_buffer_frames(capture));
    for(unsigned c=0;c<7;++c)printf("%s%.8f",c?",":"",peak[c]);puts("]}");
    pz_capture_close(capture);return received?0:3;
}
