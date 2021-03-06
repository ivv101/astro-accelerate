
//#include <omp.h>
#include <time.h>
#include <stdio.h>
#include "headers/params.h"
#include "device_zero_dm_kernel.cu"

//{{{ zero_dm

void zero_dm(unsigned short *d_input, int nchans, int nsamp, int nbits) {

	int divisions_in_t  = CT;
	int num_blocks_t    = nsamp/divisions_in_t;

	printf("\nCORNER TURN!");
	printf("\n%d %d", nsamp, nchans);
	printf("\n%d %d", divisions_in_t, 1);
	printf("\n%d %d", num_blocks_t, 1);

	dim3 threads_per_block(divisions_in_t, 1);
	dim3 num_blocks(num_blocks_t,1);

	clock_t start_t, end_t;
	start_t = clock();

	float normalization_factor = ((pow(2,nbits)-1)/2);

	zero_dm_kernel<<< num_blocks, threads_per_block >>>(d_input, nchans, nsamp, normalization_factor);
	cudaDeviceSynchronize();

	end_t = clock();
	double time = (double)(end_t-start_t) / CLOCKS_PER_SEC;
	printf("\nPerformed ZDM: %lf (GPU estimate)", time);

	//}}}

}

//}}}

