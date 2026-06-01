/**
 * @file MixerBuffers.c
 * @brief
 *
 *
 *
 *
 * @author Chris Izatt
 * @date 2025-07-23
 *
 * @details
 *
 *
 *
 *
 * @note Early or premature calls with out-of-range indices now emit warnings and return safely
 * without aborting. These calls are treated as no-ops or return defensible defaults.
 */


#include "Mixer.h"
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
