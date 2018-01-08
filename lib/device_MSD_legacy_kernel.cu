// Added by Karel Adamek 

#ifndef MSD_LEGACY_KERNEL_H_
#define MSD_LEGACY_KERNEL_H_

#include <cuda.h>
#include <cuda_runtime.h>
#include "headers/params.h"


__global__ void MSD_GPU_LA_ALL(float const* __restrict__ d_input, float *d_output, float *d_output_taps, int y_steps, int nTaps, int nTimesamples, int offset) {
	__shared__ float s_input[3*PD_NTHREADS];
	__shared__ float s_base[3*PD_NTHREADS];
	
	// MSD variables
	float M, S, j;
	float M_b, S_b, j_b;
	// FIR variables
	int d, gpos, spos, local_id;
	ushort EpT, limit;
	float2 ftemp1, ftemp2, ftemp3;
	float Bw[2];
	
	EpT = 2*PD_NTHREADS-nTaps+4;
	limit = blockDim.x - (nTaps>>2) - 1;

	// First y coordinate is separated
	//-------------------> FIR
	spos = blockIdx.x*(EpT) + 2*threadIdx.x;
	gpos = blockIdx.y*y_steps*nTimesamples + spos;
	Bw[0]=0; Bw[1]=0; j=0; j_b=0;
	if( (spos+4)<(nTimesamples-offset) ){
		// loading data for FIR filter. Each thread calculates two samples
		ftemp1.x= __ldg(&d_input[gpos]);	
		ftemp1.y= __ldg(&d_input[gpos+1]);
		ftemp2.x= __ldg(&d_input[gpos+2]);
		ftemp2.y= __ldg(&d_input[gpos+3]);
		ftemp3.x= __ldg(&d_input[gpos+4]);
		
		// Calculate FIR of 4 taps
		Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
		Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
		
		// Initialization of MSD variables for non-processed StrDev
		Initiate( &M_b, &S_b, &j_b, ftemp1.x );
		// First addition (second actually, but first done this way) non-processed StrDev
		Add_one( &M_b, &S_b, &j_b, ftemp1.y );
	}
	
	s_input[2*threadIdx.x] = Bw[0];
	s_input[2*threadIdx.x+1] = Bw[1];
	
	__syncthreads();
	
	// Calculating FIR up to nTaps
	for(d=4; d<nTaps; d=d+4){
		local_id = threadIdx.x+(d>>1);
		if( local_id<=limit ){
			Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
		}
	}
	
	// Note: threads with local_id<0 which have wrong result create sums as well but are removed from final results later
	//       same is for base values as these would be included twice. First time here and next time in threadblock next to it
	//       this is due to halo needed for FIR filter	
	Initiate( &M, &S, &j, Bw[0] ); // Initialization of MSD variables for processed StrDev
	Add_one( &M, &S, &j, Bw[1] ); // First addition (second actually, but first done this way) processed StrDev
	
	
	// Rest of the iteration in y direction	
	for (int yf = 1; yf < y_steps; yf++) {
		__syncthreads();
		//-------------------> FIR
		spos = blockIdx.x*(EpT) + 2*threadIdx.x;
		gpos = blockIdx.y*y_steps*nTimesamples + yf*nTimesamples + spos;
		Bw[0]=0; Bw[1]=0;
		if( (spos+4)<(nTimesamples-offset) ){
			ftemp1.x= __ldg(&d_input[gpos]);	
			ftemp1.y= __ldg(&d_input[gpos+1]);
			ftemp2.x= __ldg(&d_input[gpos+2]);
			ftemp2.y= __ldg(&d_input[gpos+3]);
			ftemp3.x= __ldg(&d_input[gpos+4]);

			Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
			Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
			
			Add_one( &M_b, &S_b, &j_b, ftemp1.x );
			Add_one( &M_b, &S_b, &j_b, ftemp1.y );
		}
		
		s_input[2*threadIdx.x] = Bw[0];
		s_input[2*threadIdx.x+1] = Bw[1];
	
		__syncthreads();
	
		for(d=4; d<nTaps; d=d+4){	
			local_id = threadIdx.x+(d>>1);
			if( local_id<=limit ){
				Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
			}
		}
		
		Add_one( &M, &S, &j, Bw[0] );
		Add_one( &M, &S, &j, Bw[1] );
	}
	
	__syncthreads();
	
	s_input[threadIdx.x] = 0;
	s_input[blockDim.x + threadIdx.x] = 0;
	s_input[2*blockDim.x + threadIdx.x] = 0;
	
	s_base[threadIdx.x] = 0;
	s_base[blockDim.x + threadIdx.x] = 0;
	s_base[2*blockDim.x + threadIdx.x] = 0;
	
	__syncthreads();

	spos=blockIdx.x*(EpT) + 2*threadIdx.x;	
	if( local_id<=limit ) {
		// Note: ommited number of samples in the last trailing threadblocks is due to -nTaps which is here. 
		//       Missing data should be contained in local_id. Thus this code is missing some time sample even it it does not need to. 
		//       When removed it produces different number of added time samples in j and j_b which is wierd
		if( spos<(nTimesamples-offset-nTaps) ) { // -nTaps might not be necessary
			s_input[local_id] = M;
			s_input[blockDim.x + local_id] = S;
			s_input[2*blockDim.x + local_id] = j;
			
			s_base[local_id] = M_b;
			s_base[blockDim.x + local_id] = S_b;
			s_base[2*blockDim.x + local_id] = j_b;
		}

	}
	__syncthreads();
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of processed input
	Reduce_SM( &M, &S, &j, s_input );
	Reduce_WARP( &M, &S, &j);
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of unprocessed input
	Reduce_SM( &M_b, &S_b, &j_b, s_base );
	Reduce_WARP( &M_b, &S_b, &j_b);

	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		gpos = blockIdx.y*gridDim.x + blockIdx.x;
		d_output_taps[3*gpos] = M;
		d_output_taps[3*gpos + 1] = S;
		d_output_taps[3*gpos + 2] = j;
		
		d_output[3*gpos] = M_b;
		d_output[3*gpos + 1] = S_b;
		d_output[3*gpos + 2] = j_b;
	}
}


__global__ void MSD_GPU_LA_ALL_Nth(float const* __restrict__ d_input, float const* __restrict   d_bv_in, float *d_output, float *d_output_taps, int y_steps, int nTaps, int nTimesamples, int offset) {
	__shared__ float s_input[3*PD_NTHREADS];
	__shared__ float s_base[3*PD_NTHREADS];
	
	// MSD variables
	float M, S, j;
	float M_b, S_b, j_b;
	// FIR variables
	int d, gpos, spos, local_id;
	ushort EpT, limit;
	float2 ftemp1, ftemp2, ftemp3;
	float Bw[2];
	
	EpT = 2*PD_NTHREADS-nTaps+4;
	limit = blockDim.x - (nTaps>>2) - 1;

	// First y coordinate is separated
	//-------------------> FIR
	spos = blockIdx.x*(EpT) + 2*threadIdx.x;
	gpos = blockIdx.y*y_steps*nTimesamples + spos;
	Bw[0]=0; Bw[1]=0; j=0; j_b=0;
	if( (spos+4)<(nTimesamples-offset) ){
		// loading data for FIR filter. Each thread calculates two samples
		ftemp1.x= __ldg(&d_input[gpos]);	
		ftemp1.y= __ldg(&d_input[gpos+1]);
		ftemp2.x= __ldg(&d_input[gpos+2]);
		ftemp2.y= __ldg(&d_input[gpos+3]);
		ftemp3.x= __ldg(&d_input[gpos+4]);
		
		// Calculate FIR of 4 taps
		Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
		Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
		
		Initiate( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos]) );
		Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos+1]) );
	}
	
	s_input[2*threadIdx.x] = Bw[0];
	s_input[2*threadIdx.x+1] = Bw[1];
	
	__syncthreads();
	
	// Calculating FIR up to nTaps
	for(d=4; d<nTaps; d=d+4){
		local_id = threadIdx.x+(d>>1);
		if( local_id<=limit ){
			Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
		}
	}
	
	// Note: threads with local_id<0 which have wrong result create sums as well but are removed from final results later
	//       same is for base values as these would be included twice. First time here and next time in threadblock next to it
	//       this is due to halo needed for FIR filter
	Initiate( &M, &S, &j, __ldg(&d_bv_in[gpos]) + Bw[0] );
	Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos+1]) + Bw[1] );
	
	
	// Rest of the iteration in y direction	
	for (int yf = 1; yf < y_steps; yf++) {
		__syncthreads();
		//-------------------> FIR
		spos = blockIdx.x*(EpT) + 2*threadIdx.x;
		gpos = blockIdx.y*y_steps*nTimesamples + yf*nTimesamples + spos;
		Bw[0]=0; Bw[1]=0;
		if( (spos+4)<(nTimesamples-offset) ){
			ftemp1.x= __ldg(&d_input[gpos]);	
			ftemp1.y= __ldg(&d_input[gpos+1]);
			ftemp2.x= __ldg(&d_input[gpos+2]);
			ftemp2.y= __ldg(&d_input[gpos+3]);
			ftemp3.x= __ldg(&d_input[gpos+4]);

			Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
			Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
			
			Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos]) );
			Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos+1]) );
		}
		
		s_input[2*threadIdx.x] = Bw[0];
		s_input[2*threadIdx.x+1] = Bw[1];
	
		__syncthreads();
	
		for(d=4; d<nTaps; d=d+4){	
			local_id = threadIdx.x+(d>>1);
			if( local_id<=limit ){
				Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
			}
		}
		
		Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos]) + Bw[0] );
		Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos+1]) + Bw[1] );
	}
	
	__syncthreads();
	
	s_input[threadIdx.x] = 0;
	s_input[blockDim.x + threadIdx.x] = 0;
	s_input[2*blockDim.x + threadIdx.x] = 0;
	
	s_base[threadIdx.x] = 0;
	s_base[blockDim.x + threadIdx.x] = 0;
	s_base[2*blockDim.x + threadIdx.x] = 0;
	
	__syncthreads();

	spos=blockIdx.x*(EpT) + 2*threadIdx.x;	
	if( local_id<=limit ) {		
		// Note: ommited number of samples in the last trailing threadblocks is due to -nTaps which is here. 
		//       Missing data should be contained in local_id. Thus this code is missing some time sample even it it does not need to. 
		//       When removed it produces different number of added time samples in j and j_b which is wierd
		if( spos<(nTimesamples-offset-nTaps) ) { // -nTaps might not be necessary
			s_input[local_id] = M;
			s_input[blockDim.x + local_id] = S;
			s_input[2*blockDim.x + local_id] = j;
			
			s_base[local_id] = M_b;
			s_base[blockDim.x + local_id] = S_b;
			s_base[2*blockDim.x + local_id] = j_b;
		}

	}
	__syncthreads();
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of processed input
	Reduce_SM( &M, &S, &j, s_input );
	Reduce_WARP( &M, &S, &j);
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of unprocessed input
	Reduce_SM( &M_b, &S_b, &j_b, s_base );
	Reduce_WARP( &M_b, &S_b, &j_b);

	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		gpos = blockIdx.y*gridDim.x + blockIdx.x;
		d_output_taps[3*gpos] = M;
		d_output_taps[3*gpos + 1] = S;
		d_output_taps[3*gpos + 2] = j;
		
		d_output[3*gpos] = M_b;
		d_output[3*gpos + 1] = S_b;
		d_output[3*gpos + 2] = j_b;
	}
}


__global__ void MSD_GPU_final_create_LA(float *d_input, float *d_output, float *d_MSD_base, int nTaps, int size) {
	__shared__ float s_input[3*WARP*WARP];

	float M, S, j;

	Sum_partials_regular( &M, &S, &j, d_input, s_input, size);
	
	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		d_output[0] = d_MSD_base[0];
		d_output[1] = d_MSD_base[1];
		d_output[2] = (sqrt(S / j) - d_MSD_base[1])/( (float) (nTaps-1));
	}
}


__global__ void MSD_GPU_final_create_LA_Nth(float *d_input, float *d_output, float *d_MSD_base, float *d_MSD_DIT, int nTaps, int size, int DIT_value) {
	__shared__ float s_input[3*WARP*WARP];

	float M, S, j;

	Sum_partials_regular( &M, &S, &j, d_input, s_input, size);

	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		d_output[0] = d_MSD_base[0];
		d_output[1] = d_MSD_base[1];
		d_output[2] = (sqrt(S / j) - d_MSD_base[1])/( (float) nTaps);
		d_output[3] = d_MSD_DIT[0]*DIT_value; 
	}
}



__global__ void MSD_GPU_LA_ALL_no_rejection(float const* __restrict__ d_input, float *d_output, float *d_output_taps, int y_steps, int nTaps, int nTimesamples, int offset) {
	__shared__ float s_input[3*MSD_PW_NTHREADS];
	__shared__ float s_base[3*MSD_PW_NTHREADS];
	
	// MSD variables
	float M, S, j;
	float M_b, S_b, j_b;
	// FIR variables
	int d, gpos, spos, local_id;
	ushort EpT, limit;
	float2 ftemp1, ftemp2, ftemp3;
	float Bw[2];
	
	EpT = 2*MSD_PW_NTHREADS-nTaps+4;
	limit = blockDim.x - (nTaps>>2) - 1;

	// First y coordinate is separated
	//-------------------> FIR
	spos = blockIdx.x*(EpT) + 2*threadIdx.x;
	gpos = blockIdx.y*y_steps*nTimesamples + spos;
	Bw[0]=0; Bw[1]=0; j=0; j_b=0;
	if( (spos+4)<(nTimesamples-offset) ){
		// loading data for FIR filter. Each thread calculates two samples
		ftemp1.x= __ldg(&d_input[gpos]);	
		ftemp1.y= __ldg(&d_input[gpos+1]);
		ftemp2.x= __ldg(&d_input[gpos+2]);
		ftemp2.y= __ldg(&d_input[gpos+3]);
		ftemp3.x= __ldg(&d_input[gpos+4]);
		
		// Calculate FIR of 4 taps
		Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
		Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
		
		Initiate( &M_b, &S_b, &j_b, ftemp1.x );
		Add_one( &M_b, &S_b, &j_b, ftemp1.y );
	}
	
	s_input[2*threadIdx.x] = Bw[0];
	s_input[2*threadIdx.x+1] = Bw[1];
	
	__syncthreads();
	
	// Calculating FIT up to nTaps
	for(d=4; d<nTaps; d=d+4){
		local_id = threadIdx.x+(d>>1);
		if( local_id<=limit ){
			Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
		}
	}
	
	// Note: threads with local_id<0 which have wrong result create sums as well but are removed from final results later
	//       same is for base values as these would be included twice. First time here and next time in threadblock next to it
	//       this is due to halo needed for FIR filter
	Initiate( &M, &S, &j, Bw[0] );
	Add_one( &M, &S, &j, Bw[1] );
	
	
	// Rest of the iteration in y direction	
	for (int yf = 1; yf < y_steps; yf++) {
		__syncthreads();
		//-------------------> FIR
		spos = blockIdx.x*(EpT) + 2*threadIdx.x;
		gpos = blockIdx.y*y_steps*nTimesamples + yf*nTimesamples + spos;
		Bw[0]=0; Bw[1]=0;
		if( (spos+4)<(nTimesamples-offset) ){
			ftemp1.x= __ldg(&d_input[gpos]);	
			ftemp1.y= __ldg(&d_input[gpos+1]);
			ftemp2.x= __ldg(&d_input[gpos+2]);
			ftemp2.y= __ldg(&d_input[gpos+3]);
			ftemp3.x= __ldg(&d_input[gpos+4]);

			Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
			Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
			
			Add_one( &M_b, &S_b, &j_b, ftemp1.x );
			Add_one( &M_b, &S_b, &j_b, ftemp1.y );
		}
		
		s_input[2*threadIdx.x] = Bw[0];
		s_input[2*threadIdx.x+1] = Bw[1];
	
		for(d=4; d<nTaps; d=d+4){
			local_id = threadIdx.x+(d>>1);
			if( local_id<=limit ){
				Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
			}
		}
		
		Add_one( &M, &S, &j, Bw[0] );
		Add_one( &M, &S, &j, Bw[1] );
	}
	
	__syncthreads();
	
	s_input[threadIdx.x] = 0;
	s_input[blockDim.x + threadIdx.x] = 0;
	s_input[2*blockDim.x + threadIdx.x] = 0;
	
	s_base[threadIdx.x] = 0;
	s_base[blockDim.x + threadIdx.x] = 0;
	s_base[2*blockDim.x + threadIdx.x] = 0;
	
	__syncthreads();

	spos=blockIdx.x*(EpT) + 2*threadIdx.x;	
	if( local_id<=limit ) {		
		// Note: ommited number of samples in the last trailing threadblocks is due to -nTaps which is here. 
		//       Missing data should be contained in local_id. Thus this code is missing some time sample even it it does not need to. 
		//       When removed it produces different number of added time samples in j and j_b which is wierd
		if( spos<(nTimesamples-offset-nTaps) ) { // -nTaps might not be necessary
			s_input[local_id] = M;
			s_input[blockDim.x + local_id] = S;
			s_input[2*blockDim.x + local_id] = j;
			
			s_base[local_id] = M_b;
			s_base[blockDim.x + local_id] = S_b;
			s_base[2*blockDim.x + local_id] = j_b;
		}

	}
	__syncthreads();
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of processed input
	Reduce_SM( &M, &S, &j, s_input );
	Reduce_WARP( &M, &S, &j);
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of unprocessed input
	Reduce_SM( &M_b, &S_b, &j_b, s_base );
	Reduce_WARP( &M_b, &S_b, &j_b);

	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		gpos = blockIdx.y*gridDim.x + blockIdx.x;
		d_output_taps[3*gpos] = M;
		d_output_taps[3*gpos + 1] = S;
		d_output_taps[3*gpos + 2] = j;
		
		d_output[3*gpos] = M_b;
		d_output[3*gpos + 1] = S_b;
		d_output[3*gpos + 2] = j_b;
	}
}


__global__ void MSD_BLN_pw_no_rejection(float const* __restrict__ d_input, float *d_output, int y_steps, int nTimesamples, int offset) {
	__shared__ float s_input[3*MSD_PW_NTHREADS];
	float M, S, j, ftemp;
	
	int spos = blockIdx.x*MSD_PW_NTHREADS + threadIdx.x;
	int gpos = blockIdx.y*y_steps*nTimesamples + spos;
	M=0;	S=0;	j=0;
	if( spos<(nTimesamples-offset) ){
		
		ftemp=__ldg(&d_input[gpos]);
		Initiate( &M, &S, &j, ftemp);
		
		gpos = gpos + nTimesamples;
		for (int yf = 1; yf < y_steps; yf++) {
			ftemp=__ldg(&d_input[gpos]);
			Add_one( &M, &S, &j, ftemp);
			gpos = gpos + nTimesamples;
		}
		
	}
	
	s_input[threadIdx.x] = M;
	s_input[blockDim.x + threadIdx.x] = S;
	s_input[2*blockDim.x + threadIdx.x] = j;
	
	__syncthreads();
	
	Reduce_SM( &M, &S, &j, s_input );
	Reduce_WARP( &M, &S, &j);
	
	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		gpos = blockIdx.y*gridDim.x + blockIdx.x;
		d_output[3*gpos] = M;
		d_output[3*gpos + 1] = S;
		d_output[3*gpos + 2] = j;
	}
}



__global__ void MSD_GPU_LA_ALL_pw_rejection(float const* __restrict__ d_input, float *d_output, float *d_output_taps, float *d_MSD_T, float *d_MSD_T_base, float bln_sigma_constant, int y_steps, int nTaps, int nTimesamples, int offset) {
	__shared__ float s_input[3*MSD_PW_NTHREADS];
	__shared__ float s_base[3*MSD_PW_NTHREADS];
	
	// MSD variables
	float M, S, j;
	float M_b, S_b, j_b;
	// FIR variables
	int d, gpos, spos, local_id;
	ushort EpT, limit;
	float2 ftemp1, ftemp2, ftemp3;
	float Bw[2];
	float signal_mean = d_MSD_T_base[0];
	float signal_sd = d_MSD_T_base[1];
	float signal_mean_taps = d_MSD_T[0];
	float signal_sd_taps = d_MSD_T[1];
	
	EpT = 2*MSD_PW_NTHREADS-nTaps+4;
	limit = blockDim.x - (nTaps>>2) - 1;
	
	// First y coordinate is separated
	//-------------------> FIR
	spos = blockIdx.x*(EpT) + 2*threadIdx.x;
	gpos = blockIdx.y*y_steps*nTimesamples + spos;
	Bw[0]=0; Bw[1]=0; j=0; j_b=0;
	M=0; S=0; j=0;
	M_b=0; S_b=0; j_b=0;
	if( (spos+4)<(nTimesamples-offset) ){
		// loading data for FIR filter. Each thread calculates two samples
		ftemp1.x= __ldg(&d_input[gpos]);
		ftemp1.y= __ldg(&d_input[gpos+1]);
		ftemp2.x= __ldg(&d_input[gpos+2]);
		ftemp2.y= __ldg(&d_input[gpos+3]);
		ftemp3.x= __ldg(&d_input[gpos+4]);
		
		// Initialization of MSD variables for non-processed StrDev
		Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
		Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
		
		if( (ftemp1.x > (signal_mean - bln_sigma_constant*signal_sd)) && (ftemp1.x < (signal_mean + bln_sigma_constant*signal_sd)) ){
			if(j_b==0) Initiate( &M_b, &S_b, &j_b, ftemp1.x );
			else Add_one( &M_b, &S_b, &j_b, ftemp1.x );
		}
		if( (ftemp1.y > (signal_mean - bln_sigma_constant*signal_sd)) && (ftemp1.y < (signal_mean + bln_sigma_constant*signal_sd)) ){
			if(j_b==0) Initiate( &M_b, &S_b, &j_b, ftemp1.y );
			else Add_one( &M_b, &S_b, &j_b, ftemp1.y );
		}
	}
	
	s_input[2*threadIdx.x] = Bw[0];
	s_input[2*threadIdx.x+1] = Bw[1];
	
	__syncthreads();
	
	// Calculating FIT up to nTaps
	for(d=4; d<nTaps; d=d+4){
		local_id = threadIdx.x+(d>>1);
		if( local_id<=limit ){
			Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
		}
	}
	
	// Note: threads with local_id<0 which have wrong result create sums as well but are removed from final results later
	//       same is for base values as these would be included twice. First time here and next time in threadblock next to it
	//       this is due to halo needed for FIR filter
	if( (Bw[0] > (signal_mean_taps - bln_sigma_constant*signal_sd_taps)) && (Bw[0] < (signal_mean_taps + bln_sigma_constant*signal_sd_taps)) ){
		if(j==0) Initiate( &M, &S, &j, Bw[0] );
		else Add_one( &M, &S, &j, Bw[0] );
	}
	if( (Bw[1] > (signal_mean_taps - bln_sigma_constant*signal_sd_taps)) && (Bw[1] < (signal_mean_taps + bln_sigma_constant*signal_sd_taps)) ){
		if(j==0) Initiate( &M, &S, &j, Bw[1] );
		else Add_one( &M, &S, &j, Bw[1] );
	}

	
	// Rest of the iteration in y direction	
	for (int yf = 1; yf < y_steps; yf++) {
		__syncthreads();
		//-------------------> FIR
		spos = blockIdx.x*(EpT) + 2*threadIdx.x;
		gpos = blockIdx.y*y_steps*nTimesamples + yf*nTimesamples + spos;
		Bw[0]=0; Bw[1]=0;
		if( (spos+4)<(nTimesamples-offset) ){
			ftemp1.x= __ldg(&d_input[gpos]);	
			ftemp1.y= __ldg(&d_input[gpos+1]);
			ftemp2.x= __ldg(&d_input[gpos+2]);
			ftemp2.y= __ldg(&d_input[gpos+3]);
			ftemp3.x= __ldg(&d_input[gpos+4]);

			Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
			Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
			
			if( (ftemp1.x > (signal_mean - bln_sigma_constant*signal_sd)) && (ftemp1.x < (signal_mean + bln_sigma_constant*signal_sd)) ){
				if(j_b==0) Initiate( &M_b, &S_b, &j_b, ftemp1.x );
				else Add_one( &M_b, &S_b, &j_b, ftemp1.x );
			}
			if( (ftemp1.y > (signal_mean - bln_sigma_constant*signal_sd)) && (ftemp1.y < (signal_mean + bln_sigma_constant*signal_sd)) ){
				if(j_b==0) Initiate( &M_b, &S_b, &j_b, ftemp1.y );
				else Add_one( &M_b, &S_b, &j_b, ftemp1.y );
			}
		}
		
		s_input[2*threadIdx.x] = Bw[0];
		s_input[2*threadIdx.x+1] = Bw[1];
	
		__syncthreads();
	
		for(d=4; d<nTaps; d=d+4){
			local_id = threadIdx.x+(d>>1);
			if( local_id<=limit ){
				Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
			}
		}
		
		if( (Bw[0] > (signal_mean_taps - bln_sigma_constant*signal_sd_taps)) && (Bw[0] < (signal_mean_taps + bln_sigma_constant*signal_sd_taps)) ){
			if(j==0) Initiate( &M, &S, &j, Bw[0] );
			else Add_one( &M, &S, &j, Bw[0] );
		}
		if( (Bw[1] > (signal_mean_taps - bln_sigma_constant*signal_sd_taps)) && (Bw[1] < (signal_mean_taps + bln_sigma_constant*signal_sd_taps)) ){
			if(j==0) Initiate( &M, &S, &j, Bw[1] );
			else Add_one( &M, &S, &j, Bw[1] );
		}
	}
	
	__syncthreads();
	
	s_input[threadIdx.x] = 0;
	s_input[blockDim.x + threadIdx.x] = 0;
	s_input[2*blockDim.x + threadIdx.x] = 0;
	
	s_base[threadIdx.x] = 0;
	s_base[blockDim.x + threadIdx.x] = 0;
	s_base[2*blockDim.x + threadIdx.x] = 0;
	
	__syncthreads();

	spos=blockIdx.x*(EpT) + 2*threadIdx.x;	
	if( local_id<=limit ) {		
		// Note: ommited number of samples in the last trailing threadblocks is due to -nTaps which is here. 
		//       Missing data should be contained in local_id. Thus this code is missing some time sample even it it does not need to. 
		//       When removed it produces different number of added time samples in j and j_b which is wierd
		if( spos<(nTimesamples-offset-nTaps) ) { // -nTaps might not be necessary
			s_input[local_id] = M;
			s_input[blockDim.x + local_id] = S;
			s_input[2*blockDim.x + local_id] = j;
			
			s_base[local_id] = M_b;
			s_base[blockDim.x + local_id] = S_b;
			s_base[2*blockDim.x + local_id] = j_b;
		}

	}
	__syncthreads();
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of processed input
	Reduce_SM( &M, &S, &j, s_input );
	Reduce_WARP( &M, &S, &j);
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of unprocessed input
	Reduce_SM( &M_b, &S_b, &j_b, s_base );
	Reduce_WARP( &M_b, &S_b, &j_b);

	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		gpos = blockIdx.y*gridDim.x + blockIdx.x;
		d_output_taps[3*gpos] = M;
		d_output_taps[3*gpos + 1] = S;
		d_output_taps[3*gpos + 2] = j;
		
		d_output[3*gpos] = M_b;
		d_output[3*gpos + 1] = S_b;
		d_output[3*gpos + 2] = j_b;
	}
}

/*
__global__ void MSD_BLN_pw_rejection_normal(float const* __restrict__ d_input, float *d_output, float *d_MSD, int y_steps, int nTimesamples, int offset, float bln_sigma_constant) {
	__shared__ float s_input[3*PD_NTHREADS];
	float M, S, j, ftemp;
	float limit_down = d_MSD[0] - bln_sigma_constant*d_MSD[1];
	float limit_up = d_MSD[0] + bln_sigma_constant*d_MSD[1];
	
	int spos = blockIdx.x*PD_NTHREADS + threadIdx.x;
	int gpos = blockIdx.y*y_steps*nTimesamples + spos;
	M=0;	S=0;	j=0;
	if( spos<(nTimesamples-offset) ){
		
		for (int yf = 0; yf < y_steps; yf++) {
			ftemp=__ldg(&d_input[gpos]);
			if( (ftemp>limit_down) && (ftemp < limit_up) ){
				if(j==0){
					Initiate( &M, &S, &j, ftemp);
				}
				else{
					Add_one( &M, &S, &j, ftemp);
				}			
			}
			gpos = gpos + nTimesamples;
		}
		
	}
	
	s_input[threadIdx.x] = M;
	s_input[blockDim.x + threadIdx.x] = S;
	s_input[2*blockDim.x + threadIdx.x] = j;
	
	__syncthreads();
	
	Reduce_SM( &M, &S, &j, s_input );
	
	Reduce_WARP( &M, &S, &j);
	
	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		gpos = blockIdx.y*gridDim.x + blockIdx.x;
		d_output[3*gpos] = M;
		d_output[3*gpos + 1] = S;
		d_output[3*gpos + 2] = j;
	}
}
*/

__global__ void MSD_GPU_final_create_LA_nonregular(float *d_input, float *d_output, float *d_MSD_base, int nTaps, int size) {
	__shared__ float s_input[3*WARP*WARP];

	float M, S, j;

	Sum_partials_nonregular( &M, &S, &j, d_input, s_input, size);
	
	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		d_output[0] = d_MSD_base[0];
		d_output[1] = d_MSD_base[1];
		d_output[2] = (sqrt(S / j) - d_MSD_base[1])/( (float) (nTaps-1));
	}
}


__global__ void MSD_GPU_LA_ALL_Nth_no_rejection(float const* __restrict__ d_input, float const* __restrict__ d_bv_in, float *d_output, float *d_output_taps, int y_steps, int nTaps, int nTimesamples, int offset) {
	__shared__ float s_input[3*MSD_PW_NTHREADS];
	__shared__ float s_base[3*MSD_PW_NTHREADS];
	
	// MSD variables
	float M, S, j;
	float M_b, S_b, j_b;
	// FIR variables
	int d, gpos, spos, local_id;
	ushort EpT, limit;
	float2 ftemp1, ftemp2, ftemp3;
	float Bw[2];
	
	EpT = 2*MSD_PW_NTHREADS-nTaps+4;
	limit = blockDim.x - (nTaps>>2) - 1;

	// First y iteration is separated
	//-------------------> FIR
	spos = blockIdx.x*(EpT) + 2*threadIdx.x;
	gpos = blockIdx.y*y_steps*nTimesamples + spos;
	Bw[0]=0; Bw[1]=0; M=0; S=0; M_b=0; S_b=0; j=0; j_b=0;
	if( (spos+4)<(nTimesamples-offset) ){
		// loading data for FIR filter. Each thread calculates two samples
		ftemp1.x= __ldg(&d_input[gpos]);	
		ftemp1.y= __ldg(&d_input[gpos+1]);
		ftemp2.x= __ldg(&d_input[gpos+2]);
		ftemp2.y= __ldg(&d_input[gpos+3]);
		ftemp3.x= __ldg(&d_input[gpos+4]);
		
		// Calculate FIR of 4 taps
		Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
		Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
		
		Initiate( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos]) );
		Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos+1]) );
	}
	
	s_input[2*threadIdx.x] = Bw[0];
	s_input[2*threadIdx.x+1] = Bw[1];
	
	__syncthreads();
	
	// Calculating sum of nTaps elements
	for(d=4; d<nTaps; d=d+4){
		local_id = threadIdx.x+(d>>1);
		if( local_id<=limit ){
			Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
		}
	}
	
	// Note: threads with local_id<0 which have wrong result create sums as well but are removed from final results later
	//       same is for base values as these would be included twice. First time here and next time in threadblock next to it
	//       this is due to halo needed for FIR filter
	Initiate( &M, &S, &j, __ldg(&d_bv_in[gpos]) + Bw[0] );
	Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos+1]) + Bw[1] );
	
	// Rest of the iteration in y direction	
	for (int yf = 1; yf < y_steps; yf++) {
		__syncthreads();
		//-------------------> FIR
		spos = blockIdx.x*(EpT) + 2*threadIdx.x;
		gpos = blockIdx.y*y_steps*nTimesamples + yf*nTimesamples + spos;
		Bw[0]=0; Bw[1]=0;
		if( (spos+4)<(nTimesamples-offset) ){
			ftemp1.x= __ldg(&d_input[gpos]);	
			ftemp1.y= __ldg(&d_input[gpos+1]);
			ftemp2.x= __ldg(&d_input[gpos+2]);
			ftemp2.y= __ldg(&d_input[gpos+3]);
			ftemp3.x= __ldg(&d_input[gpos+4]);

			Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
			Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
			
			Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos]) );
			Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos+1]) );
		}
		
		s_input[2*threadIdx.x] = Bw[0];
		s_input[2*threadIdx.x+1] = Bw[1];
	
		for(d=4; d<nTaps; d=d+4){
			local_id = threadIdx.x+(d>>1);
			if( local_id<=limit ){
				Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
			}
		}
		
		Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos]) + Bw[0] );
		Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos+1]) + Bw[1] );
	}
	
	__syncthreads();
	
	s_input[threadIdx.x] = 0;
	s_input[blockDim.x + threadIdx.x] = 0;
	s_input[2*blockDim.x + threadIdx.x] = 0;
	
	s_base[threadIdx.x] = 0;
	s_base[blockDim.x + threadIdx.x] = 0;
	s_base[2*blockDim.x + threadIdx.x] = 0;
	
	__syncthreads();

	spos=blockIdx.x*(EpT) + 2*threadIdx.x;	
	if( local_id<=limit ) {	
		// Note: ommited number of samples in the last trailing threadblocks is due to -nTaps which is here. 
		//       Missing data should be contained in local_id. Thus this code is missing some time sample even it it does not need to. 
		//       When removed it produces different number of added time samples in j and j_b which is wierd
		if( spos<(nTimesamples-offset-nTaps) ) { // -nTaps might not be necessary
			s_input[local_id] = M;
			s_input[blockDim.x + local_id] = S;
			s_input[2*blockDim.x + local_id] = j;
			
			s_base[local_id] = M_b;
			s_base[blockDim.x + local_id] = S_b;
			s_base[2*blockDim.x + local_id] = j_b;
		}

	}
	__syncthreads();
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of processed input
	Reduce_SM( &M, &S, &j, s_input );
	Reduce_WARP( &M, &S, &j);
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of unprocessed input
	Reduce_SM( &M_b, &S_b, &j_b, s_base );
	Reduce_WARP( &M_b, &S_b, &j_b);

	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		gpos = blockIdx.y*gridDim.x + blockIdx.x;
		d_output_taps[3*gpos] = M;
		d_output_taps[3*gpos + 1] = S;
		d_output_taps[3*gpos + 2] = j;
		
		d_output[3*gpos] = M_b;
		d_output[3*gpos + 1] = S_b;
		d_output[3*gpos + 2] = j_b;
	}
}


__global__ void MSD_GPU_LA_ALL_Nth_pw_rejection(float const* __restrict__ d_input, float const* __restrict__ d_bv_in, float *d_output, float *d_output_taps, float *d_MSD_T, float *d_MSD_T_base, float bln_sigma_constant, int y_steps, int nTaps, int nTimesamples, int offset) {
	__shared__ float s_input[3*MSD_PW_NTHREADS];
	__shared__ float s_base[3*MSD_PW_NTHREADS];
	
	// MSD variables
	float M, S, j;
	float M_b, S_b, j_b;
	// FIR variables
	int d, gpos, spos, local_id;
	ushort EpT, limit;
	float2 ftemp1, ftemp2, ftemp3;
	float Bw[2];
	//float signal_mean = d_MSD_T_base[0];
	//float signal_sd = d_MSD_T_base[1];
	float signal_mean_taps = d_MSD_T[0];
	float signal_sd_taps = d_MSD_T[1];
	
	EpT = 2*MSD_PW_NTHREADS-nTaps+4;
	limit = blockDim.x - (nTaps>>2) - 1;

	// First y coordinate is separated
	//-------------------> FIR
	spos = blockIdx.x*(EpT) + 2*threadIdx.x;
	gpos = blockIdx.y*y_steps*nTimesamples + spos;
	Bw[0]=0; Bw[1]=0; j=0; j_b=0;
	M=0; S=0; j=0;
	M_b=0; S_b=0; j_b=0;
	if( (spos+4)<(nTimesamples-offset) ){
		// loading data for FIR filter. Each thread calculates two samples
		ftemp1.x= __ldg(&d_input[gpos]);	
		ftemp1.y= __ldg(&d_input[gpos+1]);
		ftemp2.x= __ldg(&d_input[gpos+2]);
		ftemp2.y= __ldg(&d_input[gpos+3]);
		ftemp3.x= __ldg(&d_input[gpos+4]);
		
		// Calculate FIR of 4 taps
		Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
		Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
		
		//if( (__ldg(&d_bv_in[gpos]) > (signal_mean - bln_sigma_constant*signal_sd)) && (__ldg(&d_bv_in[gpos]) < (signal_mean + bln_sigma_constant*signal_sd)) ){
		//	if(j==0) Initiate( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos]) );
		//	else Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos]) );
		//}
		//if( (__ldg(&d_bv_in[gpos+1]) > (signal_mean - bln_sigma_constant*signal_sd)) && (__ldg(&d_bv_in[gpos+1]) < (signal_mean + bln_sigma_constant*signal_sd)) ){
		//	if(j==0) Initiate( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos+1]) );
		//	else Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos+1]) );
		//}
	}
	
	s_input[2*threadIdx.x] = Bw[0];
	s_input[2*threadIdx.x+1] = Bw[1];
	
	__syncthreads();
	
	// Calculating FIT up to nTaps
	for(d=4; d<nTaps; d=d+4){
		local_id = threadIdx.x+(d>>1);
		if( local_id<=limit ){
			Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
		}
	}
	
	// Note: threads with local_id<0 which have wrong result create sums as well but are removed from final results later
	//       same is for base values as these would be included twice. First time here and next time in threadblock next to it
	//       this is due to halo needed for FIR filter
	if( ( (__ldg(&d_bv_in[gpos]) + Bw[0]) > (signal_mean_taps - bln_sigma_constant*signal_sd_taps)) && ( (__ldg(&d_bv_in[gpos]) + Bw[0]) < (signal_mean_taps + bln_sigma_constant*signal_sd_taps)) ){
		if(j==0) Initiate( &M, &S, &j, __ldg(&d_bv_in[gpos]) + Bw[0] );
		else Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos]) + Bw[0] );
	}
	if( ( (__ldg(&d_bv_in[gpos+1]) + Bw[1]) > (signal_mean_taps - bln_sigma_constant*signal_sd_taps)) && ( (__ldg(&d_bv_in[gpos+1]) + Bw[1]) < (signal_mean_taps + bln_sigma_constant*signal_sd_taps)) ){
		if(j==0) Initiate( &M, &S, &j, __ldg(&d_bv_in[gpos+1]) + Bw[1] );
		else Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos+1]) + Bw[1] );
	}
	
	
	// Rest of the iteration in y direction	
	for (int yf = 1; yf < y_steps; yf++) {
		__syncthreads();
		//-------------------> FIR
		spos = blockIdx.x*(EpT) + 2*threadIdx.x;
		gpos = blockIdx.y*y_steps*nTimesamples + yf*nTimesamples + spos;
		Bw[0]=0; Bw[1]=0;
		if( (spos+4)<(nTimesamples-offset) ){
			ftemp1.x= __ldg(&d_input[gpos]);	
			ftemp1.y= __ldg(&d_input[gpos+1]);
			ftemp2.x= __ldg(&d_input[gpos+2]);
			ftemp2.y= __ldg(&d_input[gpos+3]);
			ftemp3.x= __ldg(&d_input[gpos+4]);

			Bw[0]=ftemp1.x + ftemp1.y + ftemp2.x + ftemp2.y;
			Bw[1]=ftemp1.y + ftemp2.x + ftemp2.y + ftemp3.x;
			
			//if( (__ldg(&d_bv_in[gpos]) > (signal_mean - bln_sigma_constant*signal_sd)) && (__ldg(&d_bv_in[gpos]) < (signal_mean + bln_sigma_constant*signal_sd)) ){
			//	if(j==0) Initiate( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos]) );
			//	else Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos]) );
			//}
			//if( (__ldg(&d_bv_in[gpos+1]) > (signal_mean - bln_sigma_constant*signal_sd)) && (__ldg(&d_bv_in[gpos+1]) < (signal_mean + bln_sigma_constant*signal_sd)) ){
			//	if(j==0) Initiate( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos+1]) );
			//	else Add_one( &M_b, &S_b, &j_b, __ldg(&d_bv_in[gpos+1]) );
			//}
		}
		
		s_input[2*threadIdx.x] = Bw[0];
		s_input[2*threadIdx.x+1] = Bw[1];
	
		__syncthreads();
	
		for(d=4; d<nTaps; d=d+4){
			local_id = threadIdx.x+(d>>1);
			if( local_id<=limit ){
				Bw[0] = Bw[0] + s_input[2*local_id]; Bw[1] = Bw[1] + s_input[2*local_id+1];
			}
		}
		
		if( ( (__ldg(&d_bv_in[gpos]) + Bw[0]) > (signal_mean_taps - bln_sigma_constant*signal_sd_taps)) && ( (__ldg(&d_bv_in[gpos]) + Bw[0]) < (signal_mean_taps + bln_sigma_constant*signal_sd_taps)) ){
			if(j==0) Initiate( &M, &S, &j, __ldg(&d_bv_in[gpos]) + Bw[0] );
			else Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos]) + Bw[0] );
		}
		if( ( (__ldg(&d_bv_in[gpos+1]) + Bw[1]) > (signal_mean_taps - bln_sigma_constant*signal_sd_taps)) && ( (__ldg(&d_bv_in[gpos+1]) + Bw[1]) < (signal_mean_taps + bln_sigma_constant*signal_sd_taps)) ){
			if(j==0) Initiate( &M, &S, &j, __ldg(&d_bv_in[gpos+1]) + Bw[1] );
			else Add_one( &M, &S, &j, __ldg(&d_bv_in[gpos+1]) + Bw[1] );
		}
	}
	
	__syncthreads();
	
	s_input[threadIdx.x] = 0;
	s_input[blockDim.x + threadIdx.x] = 0;
	s_input[2*blockDim.x + threadIdx.x] = 0;
	
	s_base[threadIdx.x] = 0;
	s_base[blockDim.x + threadIdx.x] = 0;
	s_base[2*blockDim.x + threadIdx.x] = 0;
	
	__syncthreads();

	spos=blockIdx.x*(EpT) + 2*threadIdx.x;	
	if( local_id<=limit ) {		
		// Note: ommited number of samples in the last trailing threadblocks is due to -nTaps which is here. 
		//       Missing data should be contained in local_id. Thus this code is missing some time sample even it it does not need to. 
		//       When removed it produces different number of added time samples in j and j_b which is wierd
		if( spos<(nTimesamples-offset-nTaps) ) { // -nTaps might not be necessary
			s_input[local_id] = M;
			s_input[blockDim.x + local_id] = S;
			s_input[2*blockDim.x + local_id] = j;
			
			s_base[local_id] = M_b;
			s_base[blockDim.x + local_id] = S_b;
			s_base[2*blockDim.x + local_id] = j_b;
		}

	}
	__syncthreads();
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of processed input
	Reduce_SM( &M, &S, &j, s_input );
	Reduce_WARP( &M, &S, &j);
	
	
	//------------------------------------------------------------------------------------
	//---------> StrDev of unprocessed input
	Reduce_SM( &M_b, &S_b, &j_b, s_base );
	Reduce_WARP( &M_b, &S_b, &j_b);

	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		gpos = blockIdx.y*gridDim.x + blockIdx.x;
		d_output_taps[3*gpos] = M;
		d_output_taps[3*gpos + 1] = S;
		d_output_taps[3*gpos + 2] = j;
		
		d_output[3*gpos] = M_b;
		d_output[3*gpos + 1] = S_b;
		d_output[3*gpos + 2] = j_b;
	}
}


__global__ void MSD_GPU_final_create_LA_Nth_nonregular(float *d_input, float *d_output, float *d_MSD_base, float *d_MSD_DIT, int nTaps, int size, int DIT_value) {
	__shared__ float s_input[3*WARP*WARP];

	float M, S, j;

	Sum_partials_nonregular( &M, &S, &j, d_input, s_input, size);
	
	//----------------------------------------------
	//---- Writing data
	if (threadIdx.x == 0) {
		d_output[0] = d_MSD_base[0];
		d_output[1] = d_MSD_base[1];
		d_output[2] = (sqrt(S / j) - d_MSD_base[1])/( (float) (nTaps));
		d_output[3] = d_MSD_DIT[0]*DIT_value;//*DIT_value
	}
}



#endif

