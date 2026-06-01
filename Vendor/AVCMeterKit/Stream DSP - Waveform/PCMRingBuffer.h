#ifndef PCMRINGBUFFER_H
#define PCMRINGBUFFER_H

#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif


typedef struct {
    float** buffers;
    int* writeIndices;
    int* readIndices;
    int capacity;
    int channelCount;
    int* fillCounts;
    pthread_mutex_t lock;
} PCMRingBuffer;

PCMRingBuffer* createPCMRingBuffer(int capacity, int channelCount);
void destroyPCMRingBuffer(PCMRingBuffer* rb);
void writePCMToRingBuffer(PCMRingBuffer* rb, float** pcmData, int frames);
int readPCMFromRingBuffer(PCMRingBuffer* rb, float** outData, int frames);
int getPCMRingBufferFillLevel(PCMRingBuffer* rb);
int getSingleChannelFillLevel(PCMRingBuffer* rb, int channelIndex);

// Functions called from Swift
void writeSingleChannelToRingBuffer(PCMRingBuffer* buffer, int channelIndex, const float* data, int frameCount, int stride);
void writeMinMaxToRingBuffer(PCMRingBuffer* buffer, float minVal, float maxVal);
int readSingleChannelFromRingBuffer(PCMRingBuffer* rb, int channelIndex, float* outData, int frames);

void FeedSingleChannelToMixer(PCMRingBuffer* rb, void* mixer, int channelIndex, int frames, int mixerChannelIndex);


#ifdef __cplusplus
}
#endif

#endif // PCMRINGBUFFER_H
