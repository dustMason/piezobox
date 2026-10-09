// Capture an explicitly selected CoreAudio device UID; never changes defaults.
// Project checks use only the named Piezo Box USB inputs.
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
static double sum[7], sum2[7], peak[7];
static unsigned long long count[7], callbacks, sequenceErrors, sampleErrors, checkedFrames;
static unsigned patternChannels, previousSequence;
static int patternEnabled, havePrevious;
static void checkPattern(const AudioBufferList* input) {
    if (!input || !input->mNumberBuffers) return;
    const AudioBuffer* buf=&input->mBuffers[0];
    if(input->mNumberBuffers!=1 || buf->mNumberChannels!=patternChannels){++sampleErrors;return;}
    const float* data=buf->mData;unsigned frames=buf->mDataByteSize/(4*patternChannels);
    const unsigned mask=patternChannels==1?255:65535;
    for(unsigned i=0;i<frames;++i) {
        unsigned values[7];
        for(unsigned ch=0;ch<patternChannels;++ch){
            long value=lrintf(data[i*patternChannels+ch]*32768);
            if(value<0||value>255)++sampleErrors;
            values[ch]=(unsigned)value&255;
        }
        unsigned sequence=values[0] | (patternChannels>1?values[1]<<8:0);
        if(havePrevious && sequence!=((previousSequence+1)&mask))++sequenceErrors;
        previousSequence=sequence;havePrevious=1;++checkedFrames;
        for(unsigned ch=2;ch<patternChannels;++ch)if(values[ch]!=((sequence*13+ch*17)&255))++sampleErrors;
    }
}
static OSStatus receive(AudioObjectID d, const AudioTimeStamp* now, const AudioBufferList* input,
    const AudioTimeStamp* it, AudioBufferList* output, const AudioTimeStamp* ot, void* context) {
    (void)d; (void)now; (void)it; (void)ot; (void)context;
    ++callbacks;
    if (output) for(unsigned b=0;b<output->mNumberBuffers;++b) if(output->mBuffers[b].mData) memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    if (!input || callbacks < 12) return 0;
    if(patternEnabled)checkPattern(input);
    unsigned firstChannel=0;
    for(unsigned b=0;b<input->mNumberBuffers;++b) {
        const AudioBuffer* buf=&input->mBuffers[b]; unsigned channels=buf->mNumberChannels;
        if(!channels || !buf->mData) continue;
        const float* data=buf->mData; unsigned frames=buf->mDataByteSize/(sizeof(float)*channels);
        for(unsigned i=0;i<frames;++i) for(unsigned ch=0;ch<channels && firstChannel+ch<7;++ch) {
            unsigned c=firstChannel+ch; double x=data[i*channels+ch];
            sum[c]+=x;sum2[c]+=x*x;peak[c]=fmax(peak[c],fabs(x));count[c]++;
        }
        firstChannel+=channels;
    }
    return 0;
}
static AudioObjectID findDevice(const char* uid) {
    AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,0};
    UInt32 size=0;if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&size))return 0;
    AudioObjectID* devices=malloc(size);if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,devices)){free(devices);return 0;}
    AudioObjectID found=0;
    for(unsigned i=0;i<size/sizeof(AudioObjectID);++i) {
        CFStringRef value=NULL;UInt32 n=sizeof(value);a=(AudioObjectPropertyAddress){kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,0};
        if(!AudioObjectGetPropertyData(devices[i],&a,0,NULL,&n,&value) && value) {
            char text[256]={0};CFStringGetCString(value,text,sizeof(text),kCFStringEncodingUTF8);CFRelease(value);
            if(!strcmp(uid,text)){found=devices[i];break;}
        }
    }
    free(devices);return found;
}
int main(int argc,char**argv) {
    if(argc<2){fprintf(stderr,"Usage: usb-audio-probe device-UID [seconds=5] [rate] [channels=7]\n");return 1;}
    const char* uid=argv[1];const unsigned channels=argc>4?atoi(argv[4]):7;
    if(channels<1||channels>7)return 1;
    patternChannels=channels;patternEnabled=argc>5 && !strcmp(argv[5],"pattern");
    AudioObjectID device=findDevice(uid);if(!device){fprintf(stderr,"Device not found: %s\n",uid);return 2;}
    AudioObjectPropertyAddress a={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,0};
    Float64 rate=0;UInt32 n=sizeof(rate);
    if(argc>3){Float64 requested=atof(argv[3]);OSStatus s=AudioObjectSetPropertyData(device,&a,0,NULL,sizeof(requested),&requested);if(s){fprintf(stderr,"Rate set failed: %d\n",(int)s);return 3;}
        for(unsigned i=0;i<30;++i){AudioObjectGetPropertyData(device,&a,0,NULL,&n,&rate);if(rate==requested)break;usleep(100000);}}
    AudioObjectGetPropertyData(device,&a,0,NULL,&n,&rate);
    printf("Device %s, %.0f Hz\n",uid,rate);fflush(stdout);
    if(argc>2 && atof(argv[2])==0)return 0;
    AudioDeviceIOProcID proc=NULL;OSStatus s=AudioDeviceCreateIOProcID(device,receive,NULL,&proc);
    if(!s)s=AudioDeviceStart(device,proc);
    if(s){fprintf(stderr,"Audio input failed: %d\n",(int)s);return 4;}
    unsigned seconds=argc>2?atoi(argv[2]):5;sleep(seconds);
    AudioDeviceStop(device,proc);AudioDeviceDestroyIOProcID(device,proc);
    printf("{\"callbacks\":%llu,\"rate\":%.0f,\"channels\":[",callbacks,rate);
    for(unsigned c=0;c<channels;++c)printf("%s{\"channel\":%u,\"samples\":%llu,\"mean\":%.9f,\"rms\":%.9f,\"peak\":%.9f}",c?",":"",c+1,count[c],count[c]?sum[c]/count[c]:0,count[c]?sqrt(sum2[c]/count[c]):0,peak[c]);
    printf("],\"pattern_frames\":%llu,\"sequence_errors\":%llu,\"sample_errors\":%llu}\n",checkedFrames,sequenceErrors,sampleErrors);
    return !callbacks?5:(patternEnabled && (!checkedFrames||sequenceErrors||sampleErrors))?6:0;
}
