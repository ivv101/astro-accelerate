#include <stdio.h>

#include "timer.h"

/* Note we send in a pointer to the file pointer becuase this function needs to update the position of the file pointer
 */

void get_file_data(FILE **fp, int *nchans, int *nsamples, int *nsamp, int *nifs, int *nbits, float *tsamp, float *tstart, float *fch1, float *foff)
{
	GpuTimer timer;

	fpos_t file_loc;

	char *string = (char *) malloc(80 * sizeof(char));

	int nchar;
	int nbytes = sizeof(int);

	unsigned long int total_data;

	double temp;

	while (1)
	{

		strcpy(string, "ERROR");
		if (fread(&nchar, sizeof(int), 1, *fp) != 1)
		{
			fprintf(stderr, "\nError while reading file\n");
			exit(0);
		}
		if (feof(*fp))
			exit(0);

		if (nchar > 1 && nchar < 80)
		{
			if (fread(string, nchar, 1, *fp) != 1)
			{
				fprintf(stderr, "\nError while reading file\n");
				exit(0);
			}

			string[nchar] = '\0';
			// For debugging only
			printf("\n%d\t%s", nchar, string), fflush(stdout);
			nbytes += nchar;

			if (strcmp(string, "HEADER_END") == 0)
				break;

			if (strcmp(string, "tsamp") == 0)
			{
				if (fread(&temp, sizeof(double), 1, *fp) != 1)
				{
					fprintf(stderr, "\nError while reading file\n");
					exit(0);
				}
				*tsamp = (float) temp;
			}
			else if (strcmp(string, "tstart") == 0)
			{
				if (fread(&temp, sizeof(double), 1, *fp) != 1)
				{
					fprintf(stderr, "\nError while reading file\n");
					exit(0);
				}
				*tstart = (float) temp;
			}
			else if (strcmp(string, "fch1") == 0)
			{
				if (fread(&temp, sizeof(double), 1, *fp) != 1)
				{
					fprintf(stderr, "\nError while reading file\n");
					exit(0);
				}
				*fch1 = (float) temp;
			}
			else if (strcmp(string, "foff") == 0)
			{
				if (fread(&temp, sizeof(double), 1, *fp) != 1)
				{
					fprintf(stderr, "\nError while reading file\n");
					exit(0);
				}
				*foff = (float) temp;
			}
			else if (strcmp(string, "nchans") == 0)
			{
				if (fread(nchans, sizeof(int), 1, *fp) != 1)
				{
					fprintf(stderr, "\nError while reading file\n");
					exit(0);
				}
			}
			else if (strcmp(string, "nifs") == 0)
			{
				if (fread(nifs, sizeof(int), 1, *fp) != 1)
				{
					fprintf(stderr, "\nError while reading file\n");
					exit(0);
				}
			}
			else if (strcmp(string, "nbits") == 0)
			{
				if (fread(nbits, sizeof(int), 1, *fp) != 1)
				{
					fprintf(stderr, "\nError while reading file\n");
					exit(0);
				}
			}
			else if (strcmp(string, "nsamples") == 0)
			{
				if (fread(nsamples, sizeof(int), 1, *fp) != 1)
				{
					fprintf(stderr, "\nError while reading file\n");
					exit(0);
				}
			}
		}
	}

	// Check that we are working with one IF channel
	if (*nifs != 1)
	{
		printf("\nERROR!! Can only work with one IF channel!\n");
		exit(1);
	}

	fgetpos(*fp, &file_loc);
	
	//-----------------------------------------------------------------
	//Testing different way of getting number of samples
	timer.Start();
	size_t data_start = ftell(*fp);
	if (fseek(*fp, 0, SEEK_END) != 0) {
		printf("\nERROR!! Failed to seek to end of data file\n");
		exit(1);
	}
	size_t exp_total_data = ftell(*fp);
	if (exp_total_data == -1) {
		printf("\nERROR!! Failed to seek to end of data file\n");
		exit(1);
	}
	exp_total_data = exp_total_data - data_start;
	fseek(*fp, data_start, SEEK_SET);
	timer.Stop();
	printf("\nAlternative way took: %f ms;\n", timer.Elapsed());
	//-----------------------------------------------------------------<

	if (( *nbits ) == 32) {
		// Allocate a temporary buffer to store a line of frequency data
		float *temp_buffer = (float *) malloc(( *nchans ) * sizeof(float));

		// Count how many time samples we have
		total_data = 0;
		while (!feof(*fp))
		{
			fread(temp_buffer, sizeof(float), ( *nchans ), *fp);
			total_data++;
		}
		*nsamp = total_data - 1;
		free(temp_buffer);
		printf("exp_total_data: %zu; nchans: %zu;\n", exp_total_data, *nchans);
		printf("For 32bit case nsamp=%zu, while faster method gives nsamp=%zu\n", *nsamp, exp_total_data/((*nchans)*4));
	}
	else if (( *nbits ) == 16)
	{
		// Allocate a tempory buffer to store a line of frequency data
		unsigned short *temp_buffer = (unsigned short *) malloc(( *nchans ) * sizeof(unsigned short));

		total_data = 0;
		while (!feof(*fp))
		{
			if (((fread(temp_buffer, sizeof(unsigned short), ( *nchans ), *fp)) != (*nchans)) && (total_data == 0))
			{
				fprintf(stderr, "\nError while reading file\n");
				exit(0);
			}
			total_data++;
		}
		*nsamp = total_data - 1;
		free(temp_buffer);
		printf("exp_total_data: %zu; nchans: %zu;\n", exp_total_data, *nchans);
		printf("For 16bit case nsamp=%zu, while faster method gives nsamp=%zu\n", *nsamp, exp_total_data/((*nchans)*2));
	}
	else if (( *nbits ) == 8) {
		timer.Start();
		// Allocate a tempory buffer to store a line of frequency data
		unsigned char *temp_buffer = (unsigned char *) malloc(( *nchans ) * sizeof(unsigned char));

		total_data = 0;
		while (!feof(*fp))
		{
			if (((fread(temp_buffer, sizeof(unsigned char), ( *nchans ), *fp)) != (*nchans)) && (total_data == 0))
			{
				fprintf(stderr, "\nError while reading file\n");
				exit(0);
			}
			total_data++;
		}
		*nsamp = total_data - 1;
		free(temp_buffer);
		printf("exp_total_data: %zu; nchans: %zu;\n", exp_total_data, *nchans);
		printf("For 8bit case nsamp=%zu, while faster method gives nsamp=%zu\n", *nsamp, exp_total_data/((*nchans)*1));
		timer.Stop();
		printf("Getting number of time samples took: %f ms;\n", timer.Elapsed());
		*nsamp = exp_total_data/((*nchans)*1);
	}
	else if (( *nbits ) == 4)
	{
		// Allocate a tempory buffer to store a line of frequency data
		// each byte stores 2 frequency data
		// assumption: nchans is a multiple of 2
		if ((*nchans % 2) != 0)
		{
			printf("\nNumber of frequency channels must be a power of 2 with 4 bit data\n");
			exit(0);
		}
		int nb_bytes = *nchans/2;
		unsigned char *temp_buffer = (unsigned char *) malloc( nb_bytes * sizeof(unsigned char));
		total_data = 0;
		while (!feof(*fp))
		{
			if (((fread(temp_buffer, sizeof(unsigned char), nb_bytes, *fp)) != nb_bytes) && (total_data == 0))
			{
				fprintf(stderr, "\nError while reading file\n");
				exit(0);
			}
			total_data++;
		}
		*nsamp = total_data - 1;
		free(temp_buffer);
	}
	else if (( *nbits ) == 2)
	{
		// Allocate a tempory buffer to store a line of frequency data
		// each byte stores 2 frequency data
		// assumption: nchans is a multiple of 2
//		if ((*nchans / 4) != 0)
//		{
//			printf("\nNumber of frequency channels must be divisible by 8 with 1 bit data samples\n");
//			exit(0);
//		}
		int nb_bytes = *nchans/4;
		unsigned char *temp_buffer = (unsigned char *) malloc( nb_bytes * sizeof(unsigned char));
		total_data = 0;
		while (!feof(*fp))
		{
			if (((fread(temp_buffer, sizeof(unsigned char), nb_bytes, *fp)) != nb_bytes) && (total_data == 0))
			{
				fprintf(stderr, "\nError while reading file\n");
				exit(0);
			}
			total_data++;
		}
		*nsamp = total_data - 1;
		free(temp_buffer);
	}
	else if (( *nbits ) == 1)
	{
		// Allocate a tempory buffer to store a line of frequency data
		// each byte stores 2 frequency data
		// assumption: nchans is a multiple of 2
//		if ((*nchans / 8) != 0)
//		{
//			printf("\nNumber of frequency channels must be divisible by 8 with 1 bit data samples\n");
//			exit(0);
//		}
		int nb_bytes = *nchans/8;
		unsigned char *temp_buffer = (unsigned char *) malloc( nb_bytes * sizeof(unsigned char));
		total_data = 0;
		while (!feof(*fp))
		{
			if (((fread(temp_buffer, sizeof(unsigned char), nb_bytes, *fp)) != nb_bytes) && (total_data == 0))
			{
				fprintf(stderr, "\nError while reading file\n");
				exit(0);
			}
			total_data++;
		}
		*nsamp = total_data - 1;
		free(temp_buffer);
	}

	else
	{
		printf("\n\n======================= ERROR ==========================\n");
		printf(    " Currently this code only runs with 1, 2, 4 8 and 16 bit data \n");
		printf(  "\n========================================================\n");
		exit(0);
	}

	// Move the file pointer back to the end of the header
	fsetpos(*fp, &file_loc);

}
