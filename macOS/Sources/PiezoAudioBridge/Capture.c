#include "PiezoCapture.h"
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define INPUT_CAPACITY 8192
struct PZCapture {
    AudioDeviceID device;
    AudioDeviceIOProcID proc;
    unsigned channels, bufferFrames;
    _Atomic uint64_t read, write, total, dropped, discontinuities;
    _Atomic bool stopping;
    bool haveTime;
    double nextTime;
    float samples[];
};
static OSStatus input_callback(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
    const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime, void* context) {
    (void)device;(void)now;(void)outputTime;
    PZCapture* c=context;
    if(output)for(unsigned b=0;b<output->mNumberBuffers;++b)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    if(atomic_load_explicit(&c->stopping,memory_order_relaxed)||!input||!input->mNumberBuffers)return 0;
    unsigned frames=UINT32_MAX, channels=0;
    for(unsigned b=0;b<input->mNumberBuffers;++b){
        const AudioBuffer* buffer=&input->mBuffers[b];if(!buffer->mNumberChannels||!buffer->mData)continue;
        unsigned n=buffer->mDataByteSize/(sizeof(float)*buffer->mNumberChannels);
        if(n<frames)frames=n;channels+=buffer->mNumberChannels;
    }
    if(channels!=c->channels||frames==UINT32_MAX||!frames)return 0;
    if(inputTime && (inputTime->mFlags & kAudioTimeStampSampleTimeValid)){
        double delta=inputTime->mSampleTime-c->nextTime;
        if(c->haveTime && fabs(delta)>0.5){atomic_fetch_add(&c->discontinuities,1);if(delta>0)atomic_fetch_add(&c->dropped,(uint64_t)llround(delta));}
        c->haveTime=true;c->nextTime=inputTime->mSampleTime+frames;
    }
    atomic_fetch_add_explicit(&c->total,frames,memory_order_relaxed);
    uint64_t write=atomic_load_explicit(&c->write,memory_order_relaxed),read=atomic_load_explicit(&c->read,memory_order_acquire);
    if(write-read+frames>=INPUT_CAPACITY){atomic_fetch_add(&c->dropped,frames);atomic_fetch_add(&c->discontinuities,1);return 0;}
    for(unsigned f=0;f<frames;++f){
        float* destination=c->samples+((write+f)%INPUT_CAPACITY)*c->channels;unsigned offset=0;
        for(unsigned b=0;b<input->mNumberBuffers;++b){
            const AudioBuffer* buffer=&input->mBuffers[b];if(!buffer->mNumberChannels||!buffer->mData)continue;
            const float* source=(const float*)buffer->mData+f*buffer->mNumberChannels;
            memcpy(destination+offset,source,buffer->mNumberChannels*sizeof(float));offset+=buffer->mNumberChannels;
        }
    }
    atomic_store_explicit(&c->write,write+frames,memory_order_release);return 0;
}
PZCapture* pz_capture_open(uint32_t device,uint32_t channels,int32_t* error){
    *error=0;if(channels!=7){*error=kAudioHardwareIllegalOperationError;return NULL;}
    AudioObjectPropertyAddress address={kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput,0};
    UInt32 size=0;*error=AudioObjectGetPropertyDataSize(device,&address,0,NULL,&size);if(*error)return NULL;
    if(size!=sizeof(AudioStreamID)){*error=kAudioDeviceUnsupportedFormatError;return NULL;}
    AudioStreamID stream=0;*error=AudioObjectGetPropertyData(device,&address,0,NULL,&size,&stream);if(*error)return NULL;
    AudioStreamBasicDescription format={0};size=sizeof(format);
    address=(AudioObjectPropertyAddress){kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal,0};
    *error=AudioObjectGetPropertyData(stream,&address,0,NULL,&size,&format);if(*error)return NULL;
    if(format.mFormatID!=kAudioFormatLinearPCM||!(format.mFormatFlags&kAudioFormatFlagIsFloat)||format.mBitsPerChannel!=32||format.mChannelsPerFrame!=channels||format.mSampleRate!=32000){*error=kAudioDeviceUnsupportedFormatError;return NULL;}
    PZCapture* c=calloc(1,sizeof(PZCapture)+INPUT_CAPACITY*channels*sizeof(float));if(!c){*error=kAudioHardwareUnspecifiedError;return NULL;}
    c->device=device;c->channels=channels;
    // Request a small device quantum for drum latency. If another client or the
    // driver rejects it, capture still works at the device's existing quantum.
    address=(AudioObjectPropertyAddress){kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,0};
    UInt32 requested=128;AudioObjectSetPropertyData(device,&address,0,NULL,sizeof(requested),&requested);
    size=sizeof(c->bufferFrames);AudioObjectGetPropertyData(device,&address,0,NULL,&size,&c->bufferFrames);
    for(unsigned i=0;i<INPUT_CAPACITY*channels;i+=1024)((volatile float*)c->samples)[i]=0;
    *error=AudioDeviceCreateIOProcID(device,input_callback,c,&c->proc);
    if(!*error)*error=AudioDeviceStart(device,c->proc);
    if(*error){if(c->proc)AudioDeviceDestroyIOProcID(device,c->proc);free(c);return NULL;}
    return c;
}
void pz_capture_close(PZCapture* c){if(!c)return;atomic_store(&c->stopping,true);AudioDeviceStop(c->device,c->proc);AudioDeviceDestroyIOProcID(c->device,c->proc);free(c);}
unsigned pz_capture_read(PZCapture* c,float* data,unsigned maxFrames){
    uint64_t read=atomic_load_explicit(&c->read,memory_order_relaxed),write=atomic_load_explicit(&c->write,memory_order_acquire);
    unsigned count=(unsigned)(write-read);if(count>maxFrames)count=maxFrames;
    for(unsigned f=0;f<count;++f)memcpy(data+f*c->channels,c->samples+((read+f)%INPUT_CAPACITY)*c->channels,c->channels*sizeof(float));
    atomic_store_explicit(&c->read,read+count,memory_order_release);return count;
}
uint64_t pz_capture_total(PZCapture* c){return atomic_load(&c->total);}
uint64_t pz_capture_dropped(PZCapture* c){return atomic_load(&c->dropped);}
uint64_t pz_capture_discontinuities(PZCapture* c){return atomic_load(&c->discontinuities);}
unsigned pz_capture_buffer_frames(PZCapture* c){return c->bufferFrames;}
