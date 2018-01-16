// James Sharpe's peak finding code

#include "headers/device_BC_plan.h"

#include <npp.h>
#include "helper_cuda.h"

#include "headers/params.h"
#include "device_peak_find_kernel.cu"


void PEAK_FIND(float *d_output_SNR, ushort *d_output_taps, float *d_peak_list, int nDMs, int nTimesamples, float threshold, int max_peak_size, int *gmem_peak_pos, int shift, std::vector<PulseDetection_plan> *PD_plan, int max_iteration){
	int decimated_timesamples, local_offset;
	
	
	dim3 blockDim(32, 2, 1);
	dim3 gridSize(1, 1, 1);
		
	
	for(int f=0; f<max_iteration; f++){
		decimated_timesamples = PD_plan->operator[](f).decimated_timesamples;
		//local_offset = offset>>f;
		local_offset = PD_plan->operator[](f).unprocessed_samples;
		if( (decimated_timesamples-local_offset-1)>0 ){		
			gridSize.x = 1 + ((decimated_timesamples-local_offset-1)/blockDim.x);
			gridSize.y = 1 + ((nDMs-1)/blockDim.y);
			gridSize.z = 1;		
			
			dilate_peak_find<<<gridSize, blockDim>>>(&d_output_SNR[nDMs*PD_plan->operator[](f).output_shift], &d_output_taps[nDMs*PD_plan->operator[](f).output_shift], d_peak_list, decimated_timesamples, nDMs, local_offset, threshold, max_peak_size, gmem_peak_pos, shift, (1<<f));
		}
	}
}

void PEAK_FIND_FOR_FDAS(float *d_ffdot_plane, float *d_peak_list, float *d_MSD, int nDMs, int nTimesamples, float threshold, unsigned int max_peak_size, unsigned int *gmem_peak_pos, float DM_trial) {
	dim3 blockDim(32, 2, 1);
	dim3 gridSize(1 + ((nTimesamples-1)/blockDim.x), 1 + ((nDMs-1)/blockDim.y), 1);
	
	dilate_peak_find_for_fdas<<<gridSize, blockDim>>>( d_ffdot_plane, d_peak_list, d_MSD, nTimesamples, nDMs, 0, threshold, max_peak_size, gmem_peak_pos, DM_trial);
}

void Peak_find_for_periodicity_search_old(float *d_input_SNR, ushort *d_input_harmonics, float *d_peak_list, int nDMs, int nTimesamples, float threshold, int max_peak_size, int *gmem_peak_pos, float *d_MSD, int DM_shift, int inBin){
	dim3 blockDim(32, 32, 1);
	dim3 gridSize(1 + ((nTimesamples-1)/blockDim.x), 1 + ((nDMs-1)/blockDim.y), 1);
	
	dilate_peak_find_for_periods_old<<<gridSize, blockDim>>>(d_input_SNR, d_input_harmonics, d_peak_list, nTimesamples, nDMs, 0, threshold, max_peak_size, gmem_peak_pos, d_MSD, DM_shift, inBin);
}

void Peak_find_for_periodicity_search(float *d_input_SNR, ushort *d_input_harmonics, float *d_peak_list, int nDMs, int nTimesamples, float threshold, int max_peak_size, int *gmem_peak_pos, float *d_MSD, int DM_shift, int inBin){
	dim3 blockDim(32, 32, 1);
	dim3 gridSize(1 + ((nTimesamples-1)/blockDim.x), 1 + ((nDMs-1)/blockDim.y), 1);
	
	dilate_peak_find_for_periods<<<gridSize, blockDim>>>(d_input_SNR, d_input_harmonics, d_peak_list, nTimesamples, nDMs, 0, threshold, max_peak_size, gmem_peak_pos, d_MSD, DM_shift, inBin);
}

void gpu_Filter_peaks(float *d_new_peak_list, float *d_old_peak_list, int nElements, float max_distance, int max_list_pos, int *gmem_peak_pos){
	int nThreads, nBlocks_x, nLoops;
	
	nThreads=64;
	
		nBlocks_x = nElements/PPF_PEAKS_PER_BLOCK;
		//if(nElements%PPF_PEAKS_PER_BLOCK!=0) nBlocks_x++;
		nLoops = nElements/PPF_DPB;
		//if(nElements%PPF_DPB!=0) nLoops++;
		
		
		dim3 blockDim(nThreads, 1, 1);
		dim3 gridSize(nBlocks_x, 1, 1);	
	if(nBlocks_x>0){	
		gpu_Filter_peaks_kernel<<<gridSize, blockDim>>>( (float4 *) d_new_peak_list, (float4 *) d_old_peak_list, nElements, max_distance*max_distance, nLoops, max_list_pos, gmem_peak_pos);
	}
}
