/*! \file CTU_3D_cuda.cu
 *  \brief Definitions of the cuda 3D CTU algorithm functions. */

#ifdef CUDA

#include<stdio.h>
#include<stdlib.h>
#include<math.h>
#include<cuda.h>
#include"global.h"
#include"global_cuda.h"
#include"CTU_3D_cuda.h"
#include"pcm_cuda.h"
#include"plmp_ctu_cuda.h"
#include"plmc_ctu_cuda.h"
#include"ppmp_ctu_cuda.h"
#include"ppmc_ctu_cuda.h"
#include"exact_cuda.h"
#include"roe_cuda.h"
#include"h_correction_3D_cuda.h"
#include"cooling_cuda.h"
#include"subgrid_routines_3D.h"



__global__ void Evolve_Interface_States_3D(Real *dev_conserved, Real *dev_Q_Lx, Real *dev_Q_Rx, Real *dev_F_x,
                                           Real *dev_Q_Ly, Real *dev_Q_Ry, Real *dev_F_y,
                                           Real *dev_Q_Lz, Real *dev_Q_Rz, Real *dev_F_z,
                                           int nx, int ny, int nz, int n_ghost, Real dx, Real dy, Real dz, Real dt);

__global__ void Update_Conserved_Variables_3D(Real *dev_conserved, Real *dev_F_x, Real *dev_F_y,  Real *dev_F_z,
                                              int nx, int ny, int nz, int n_ghost, Real dx, Real dy, Real dz, Real dt, Real gamma);

__global__ void Calc_dt_3D(Real *dev_conserved, int nx, int ny, int nz, int n_ghost, Real dx, Real dy, Real dz, Real *dti_array, Real gamma);

__global__ void Sync_Energies_3D(Real *dev_conserved, int nx, int ny, int nz, int n_ghost, Real gamma);



Real CTU_Algorithm_3D_CUDA(Real *host_conserved, int nx, int ny, int nz, int n_ghost, Real dx, Real dy, Real dz, Real dt)
{
  //Here, *host_conserved contains the entire
  //set of conserved variables on the grid
  //concatenated into a 1-d array

  int n_fields = 5;
  #ifdef DE
  n_fields = 6;
  #endif

  // dimensions of subgrid blocks
  int nx_s; //number of cells in the subgrid block along x direction
  int ny_s; //number of cells in the subgrid block along y direction
  int nz_s; //number of cells in the subgrid block along z direction

  // total number of blocks needed
  int block_tot;    //total number of subgrid blocks (unsplit == 1)
  int block1_tot;   //total number of subgrid blocks in x direction
  int block2_tot;   //total number of subgrid blocks in y direction
  int block3_tot;   //total number of subgrid blocks in z direction 
  int remainder1;   //modulus of number of cells after block subdivision in x direction
  int remainder2;   //modulus of number of cells after block subdivision in y direction 
  int remainder3;   //modulus of number of cells after block subdivision in z direction

  // counter for which block we're on
  int block = 0;

   
  // calculate the dimensions for each subgrid block
  sub_dimensions_3D(nx, ny, nz, n_ghost, &nx_s, &ny_s, &nz_s, &block1_tot, &block2_tot, &block3_tot, &remainder1, &remainder2, &remainder3, n_fields);
  block_tot = block1_tot*block2_tot*block3_tot;

  // number of cells in one subgrid block
  int BLOCK_VOL = nx_s*ny_s*nz_s;

  // define the dimensions for the 1D grid
  int  ngrid = (BLOCK_VOL + TPB - 1) / TPB;

  //number of blocks per 1-d grid  
  dim3 dim1dGrid(ngrid, 1, 1);

  //number of threads per 1-d block   
  dim3 dim1dBlock(TPB, 1, 1);


  // allocate buffer arrays to copy conserved variable slices into
  Real **buffer;
  allocate_buffers_3D(block1_tot, block2_tot, block3_tot, BLOCK_VOL, buffer, n_fields);
  // and set up pointers for the location to copy from and to
  Real *tmp1;
  Real *tmp2;

  // allocate an array on the CPU to hold max_dti returned from each thread block
  Real max_dti = 0;
  Real *host_dti_array;
  host_dti_array = (Real *) malloc(ngrid*sizeof(Real));

  // allocate GPU arrays
  // conserved variables
  Real *dev_conserved;
  // input states and associated interface fluxes (Q* and F* from Stone, 2008)
  Real *Q_Lx, *Q_Rx, *Q_Ly, *Q_Ry, *Q_Lz, *Q_Rz, *F_x, *F_y, *F_z;
#ifdef H_CORRECTION
  // arrays to hold the eta values for the H correction
  Real *eta_x, *eta_y, *eta_z, *etah_x, *etah_y, *etah_z;
#endif
  // array of inverse timesteps for dt calculation
  Real *dev_dti_array;


  // allocate memory on the GPU
  CudaSafeCall( cudaMalloc((void**)&dev_conserved, n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&Q_Lx,  n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&Q_Rx,  n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&Q_Ly,  n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&Q_Ry,  n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&Q_Lz,  n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&Q_Rz,  n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&F_x,   n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&F_y,   n_fields*BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&F_z,   n_fields*BLOCK_VOL*sizeof(Real)) );
#ifdef H_CORRECTION
  CudaSafeCall( cudaMalloc((void**)&eta_x,  BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&eta_y,  BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&eta_z,  BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&etah_x, BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&etah_y, BLOCK_VOL*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&etah_z, BLOCK_VOL*sizeof(Real)) );
#endif
  CudaSafeCall( cudaMalloc((void**)&dev_dti_array, ngrid*sizeof(Real)) );


  // transfer first conserved variable slice into the first buffer
  host_copy_init_3D(nx, ny, nz, nx_s, ny_s, nz_s, n_ghost, block, block1_tot, block2_tot, remainder1, remainder2, BLOCK_VOL, host_conserved, buffer, &tmp1, &tmp2, n_fields);


  // START LOOP OVER SUBGRID BLOCKS HERE
  while (block < block_tot) {

  // zero the GPU arrays
  cudaMemset(dev_conserved, 0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(Q_Lx,  0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(Q_Rx,  0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(Q_Ly,  0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(Q_Ry,  0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(Q_Lz,  0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(Q_Rz,  0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(F_x,   0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(F_y,   0, n_fields*BLOCK_VOL*sizeof(Real));
  cudaMemset(F_z,   0, n_fields*BLOCK_VOL*sizeof(Real));
#ifdef H_CORRECTION
  cudaMemset(eta_x,  0, BLOCK_VOL*sizeof(Real));
  cudaMemset(eta_y,  0, BLOCK_VOL*sizeof(Real));
  cudaMemset(eta_z,  0, BLOCK_VOL*sizeof(Real));
  cudaMemset(etah_x, 0, BLOCK_VOL*sizeof(Real));
  cudaMemset(etah_y, 0, BLOCK_VOL*sizeof(Real));
  cudaMemset(etah_z, 0, BLOCK_VOL*sizeof(Real));
#endif
  cudaMemset(dev_dti_array, 0, ngrid*sizeof(Real));  
  CudaCheckError();


  // copy the conserved variables onto the GPU
  CudaSafeCall( cudaMemcpy(dev_conserved, tmp1, n_fields*BLOCK_VOL*sizeof(Real), cudaMemcpyHostToDevice) );
  

  // Step 1: Do the reconstruction
  #ifdef PCM
  PCM_Reconstruction_3D<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lx, Q_Rx, Q_Ly, Q_Ry, Q_Lz, Q_Rz, nx_s, ny_s, nz_s, n_ghost, gama);
  #endif //PCM
  #ifdef PLMP
  PLMP_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lx, Q_Rx, nx_s, ny_s, nz_s, n_ghost, dx, dt, gama, 0);
  PLMP_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Ly, Q_Ry, nx_s, ny_s, nz_s, n_ghost, dy, dt, gama, 1);
  PLMP_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lz, Q_Rz, nx_s, ny_s, nz_s, n_ghost, dz, dt, gama, 2);
  #endif //PLMP 
  #ifdef PLMC
  PLMC_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lx, Q_Rx, nx_s, ny_s, nz_s, n_ghost, dx, dt, gama, 0);
  PLMC_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Ly, Q_Ry, nx_s, ny_s, nz_s, n_ghost, dy, dt, gama, 1);
  PLMC_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lz, Q_Rz, nx_s, ny_s, nz_s, n_ghost, dz, dt, gama, 2);
  #endif //PLMC 
  #ifdef PPMP
  PPMP_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lx, Q_Rx, nx_s, ny_s, nz_s, n_ghost, dx, dt, gama, 0);
  PPMP_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Ly, Q_Ry, nx_s, ny_s, nz_s, n_ghost, dy, dt, gama, 1);
  PPMP_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lz, Q_Rz, nx_s, ny_s, nz_s, n_ghost, dz, dt, gama, 2);
  #endif //PPMP
  #ifdef PPMC
  PPMC_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lx, Q_Rx, nx_s, ny_s, nz_s, n_ghost, dx, dt, gama, 0);
  PPMC_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Ly, Q_Ry, nx_s, ny_s, nz_s, n_ghost, dy, dt, gama, 1);
  PPMC_CTU<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lz, Q_Rz, nx_s, ny_s, nz_s, n_ghost, dz, dt, gama, 2);
  #endif //PPMC
  CudaCheckError();


  #ifdef H_CORRECTION
  #ifndef CTU
  calc_eta_x_3D<<<dim1dGrid,dim1dBlock>>>(Q_Lx, Q_Rx, eta_x, nx_s, ny_s, nz_s, n_ghost, gama);
  calc_eta_y_3D<<<dim1dGrid,dim1dBlock>>>(Q_Ly, Q_Ry, eta_y, nx_s, ny_s, nz_s, n_ghost, gama);
  calc_eta_z_3D<<<dim1dGrid,dim1dBlock>>>(Q_Lz, Q_Rz, eta_z, nx_s, ny_s, nz_s, n_ghost, gama);
  CudaCheckError();
  // and etah values for each interface
  calc_etah_x_3D<<<dim1dGrid,dim1dBlock>>>(eta_x, eta_y, eta_z, etah_x, nx_s, ny_s, nz_s, n_ghost);
  calc_etah_y_3D<<<dim1dGrid,dim1dBlock>>>(eta_x, eta_y, eta_z, etah_y, nx_s, ny_s, nz_s, n_ghost);
  calc_etah_z_3D<<<dim1dGrid,dim1dBlock>>>(eta_x, eta_y, eta_z, etah_z, nx_s, ny_s, nz_s, n_ghost);
  CudaCheckError();
  #endif // NO CTU
  #endif // H_CORRECTION


  // Step 2: Calculate the fluxes
  #ifdef EXACT
  Calculate_Exact_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Lx, Q_Rx, F_x, nx_s, ny_s, nz_s, n_ghost, gama, 0);
  Calculate_Exact_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Ly, Q_Ry, F_y, nx_s, ny_s, nz_s, n_ghost, gama, 1);
  Calculate_Exact_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Lz, Q_Rz, F_z, nx_s, ny_s, nz_s, n_ghost, gama, 2);
  #endif //EXACT

  #ifdef ROE
  Calculate_Roe_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Lx, Q_Rx, F_x, nx_s, ny_s, nz_s, n_ghost, gama, etah_x, 0);
  Calculate_Roe_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Ly, Q_Ry, F_y, nx_s, ny_s, nz_s, n_ghost, gama, etah_y, 1);
  Calculate_Roe_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Lz, Q_Rz, F_z, nx_s, ny_s, nz_s, n_ghost, gama, etah_z, 2);
  #endif //ROE
  CudaCheckError();


#ifdef CTU
  // Step 3: Evolve the interface states
  Evolve_Interface_States_3D<<<dim1dGrid,dim1dBlock>>>(dev_conserved, Q_Lx, Q_Rx, F_x, Q_Ly, Q_Ry, F_y, Q_Lz, Q_Rz, F_z, nx_s, ny_s, nz_s, n_ghost, dx, dy, dz, dt);
  CudaCheckError();

  #ifdef H_CORRECTION
  // Step 3.5: Calculate eta values for H correction
  calc_eta_x_3D<<<dim1dGrid,dim1dBlock>>>(Q_Lx, Q_Rx, eta_x, nx_s, ny_s, nz_s, n_ghost, gama);
  calc_eta_y_3D<<<dim1dGrid,dim1dBlock>>>(Q_Ly, Q_Ry, eta_y, nx_s, ny_s, nz_s, n_ghost, gama);
  calc_eta_z_3D<<<dim1dGrid,dim1dBlock>>>(Q_Lz, Q_Rz, eta_z, nx_s, ny_s, nz_s, n_ghost, gama);
  CudaCheckError();
  // and etah values for each interface
  calc_etah_x_3D<<<dim1dGrid,dim1dBlock>>>(eta_x, eta_y, eta_z, etah_x, nx_s, ny_s, nz_s, n_ghost);
  calc_etah_y_3D<<<dim1dGrid,dim1dBlock>>>(eta_x, eta_y, eta_z, etah_y, nx_s, ny_s, nz_s, n_ghost);
  calc_etah_z_3D<<<dim1dGrid,dim1dBlock>>>(eta_x, eta_y, eta_z, etah_z, nx_s, ny_s, nz_s, n_ghost);
  CudaCheckError();
  #endif //H_CORRECTION


  // Step 4: Calculate the fluxes again
  #ifdef EXACT
  Calculate_Exact_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Lx, Q_Rx, F_x, nx_s, ny_s, nz_s, n_ghost, gama, 0);
  Calculate_Exact_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Ly, Q_Ry, F_y, nx_s, ny_s, nz_s, n_ghost, gama, 1);
  Calculate_Exact_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Lz, Q_Rz, F_z, nx_s, ny_s, nz_s, n_ghost, gama, 2);
  #endif //EXACT

  #ifdef ROE
  Calculate_Roe_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Lx, Q_Rx, F_x, nx_s, ny_s, nz_s, n_ghost, gama, etah_x, 0);
  Calculate_Roe_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Ly, Q_Ry, F_y, nx_s, ny_s, nz_s, n_ghost, gama, etah_y, 1);
  Calculate_Roe_Fluxes<<<dim1dGrid,dim1dBlock>>>(Q_Lz, Q_Rz, F_z, nx_s, ny_s, nz_s, n_ghost, gama, etah_z, 2);
  #endif //ROE
  CudaCheckError();
#endif //CTU

  // Step 5: Update the conserved variable array
  Update_Conserved_Variables_3D<<<dim1dGrid,dim1dBlock>>>(dev_conserved, F_x, F_y, F_z, nx_s, ny_s, nz_s, n_ghost, dx, dy, dz, dt, gama);
  CudaCheckError();

  // Synchronize the total and internal energies
  #ifdef DE
  Sync_Energies_3D<<<dim1dGrid,dim1dBlock>>>(dev_conserved, nx_s, ny_s, nz_s, n_ghost, gama);
  CudaCheckError();
  #endif

  // Apply cooling
  #ifdef COOLING_GPU
  cooling_kernel<<<dim1dGrid,dim1dBlock>>>(dev_conserved, nx_s, ny_s, nz_s, n_ghost, dt, gama);
  CudaCheckError();
  #endif

  // Step 6: Calculate the next timestep
  Calc_dt_3D<<<dim1dGrid,dim1dBlock>>>(dev_conserved, nx_s, ny_s, nz_s, n_ghost, dx, dy, dz, dev_dti_array, gama);
  CudaCheckError();

  // copy the updated conserved variable array back to the CPU
  CudaSafeCall( cudaMemcpy(tmp2, dev_conserved, n_fields*BLOCK_VOL*sizeof(Real), cudaMemcpyDeviceToHost) );

  // copy the next conserved variable blocks into appropriate buffers
  host_copy_next_3D(nx, ny, nz, nx_s, ny_s, nz_s, n_ghost, block, block1_tot, block2_tot, block3_tot, remainder1, remainder2, remainder3, BLOCK_VOL, host_conserved, buffer, &tmp1, n_fields);

  // copy the updated conserved variable array back into the host_conserved array on the CPU
  host_return_values_3D(nx, ny, nz, nx_s, ny_s, nz_s, n_ghost, block, block1_tot, block2_tot, block3_tot, remainder1, remainder2, remainder3, BLOCK_VOL, host_conserved, buffer, n_fields);

  // copy the dti array onto the CPU
  CudaSafeCall( cudaMemcpy(host_dti_array, dev_dti_array, ngrid*sizeof(Real), cudaMemcpyDeviceToHost) );
  // iterate through to find the maximum inverse dt for this subgrid block
  for (int i=0; i<ngrid; i++) {
    max_dti = fmax(max_dti, host_dti_array[i]);
  }


  // add one to the counter
  block++;

}


  // free CPU memory
  free(host_dti_array);  
  free_buffers_3D(nx, ny, nz, nx_s, ny_s, nz_s, block1_tot, block2_tot, block3_tot, buffer);


  // free the GPU memory
  cudaFree(dev_conserved);
  cudaFree(Q_Lx);
  cudaFree(Q_Rx);
  cudaFree(Q_Ly);
  cudaFree(Q_Ry);
  cudaFree(Q_Lz);
  cudaFree(Q_Rz);
  cudaFree(F_x);
  cudaFree(F_y);
  cudaFree(F_z);
#ifdef H_CORRECTION
  cudaFree(eta_x);
  cudaFree(eta_y);
  cudaFree(eta_z);
  cudaFree(etah_x);
  cudaFree(etah_y);
  cudaFree(etah_z);
#endif
  cudaFree(dev_dti_array);


  // return the maximum inverse timestep
  return max_dti;

}


__global__ void Evolve_Interface_States_3D(Real *dev_conserved, Real *dev_Q_Lx, Real *dev_Q_Rx, Real *dev_F_x,
                                           Real *dev_Q_Ly, Real *dev_Q_Ry, Real *dev_F_y,
                                           Real *dev_Q_Lz, Real *dev_Q_Rz, Real *dev_F_z,
                                           int nx, int ny, int nz, int n_ghost, Real dx, Real dy, Real dz, Real dt)
{
  Real dtodx = dt/dx;
  Real dtody = dt/dy;
  Real dtodz = dt/dz;
  int n_cells = nx*ny*nz;

  // get a thread ID
  int tid = threadIdx.x + blockIdx.x * blockDim.x;
  int zid = tid / (nx*ny);
  int yid = (tid - zid*nx*ny) / nx;
  int xid = tid - zid*nx*ny - yid*nx;
  int id = xid + yid*nx + zid*nx*ny;

  if (xid > n_ghost-3 && xid < nx-n_ghost+1 && yid > n_ghost-2 && yid < ny-n_ghost+1 && zid > n_ghost-2 && zid < nz-n_ghost+1)
  {
    // set the new x interface states
    // left
    int ipo = xid+1 + yid*nx + zid*nx*ny;
    int jmo = xid + (yid-1)*nx + zid*nx*ny;
    int kmo = xid + yid*nx + (zid-1)*nx*ny;
    int ipojmo = xid+1 + (yid-1)*nx + zid*nx*ny;
    int ipokmo = xid+1 + yid*nx + (zid-1)*nx*ny;
    dev_Q_Lx[            id] += 0.5*dtody*(dev_F_y[            jmo] - dev_F_y[            id])
                              + 0.5*dtodz*(dev_F_z[            kmo] - dev_F_z[            id]);
    dev_Q_Lx[  n_cells + id] += 0.5*dtody*(dev_F_y[  n_cells + jmo] - dev_F_y[  n_cells + id])
                              + 0.5*dtodz*(dev_F_z[  n_cells + kmo] - dev_F_z[  n_cells + id]);
    dev_Q_Lx[2*n_cells + id] += 0.5*dtody*(dev_F_y[2*n_cells + jmo] - dev_F_y[2*n_cells + id])
                              + 0.5*dtodz*(dev_F_z[2*n_cells + kmo] - dev_F_z[2*n_cells + id]);
    dev_Q_Lx[3*n_cells + id] += 0.5*dtody*(dev_F_y[3*n_cells + jmo] - dev_F_y[3*n_cells + id])
                              + 0.5*dtodz*(dev_F_z[3*n_cells + kmo] - dev_F_z[3*n_cells + id]);
    dev_Q_Lx[4*n_cells + id] += 0.5*dtody*(dev_F_y[4*n_cells + jmo] - dev_F_y[4*n_cells + id])
                              + 0.5*dtodz*(dev_F_z[4*n_cells + kmo] - dev_F_z[4*n_cells + id]);

    // right
    dev_Q_Rx[            id] += 0.5*dtody*(dev_F_y[            ipojmo] - dev_F_y[            ipo])
                              + 0.5*dtodz*(dev_F_z[            ipokmo] - dev_F_z[            ipo]); 
    dev_Q_Rx[  n_cells + id] += 0.5*dtody*(dev_F_y[  n_cells + ipojmo] - dev_F_y[  n_cells + ipo])
                              + 0.5*dtodz*(dev_F_z[  n_cells + ipokmo] - dev_F_z[  n_cells + ipo]);
    dev_Q_Rx[2*n_cells + id] += 0.5*dtody*(dev_F_y[2*n_cells + ipojmo] - dev_F_y[2*n_cells + ipo])
                              + 0.5*dtodz*(dev_F_z[2*n_cells + ipokmo] - dev_F_z[2*n_cells + ipo]);
    dev_Q_Rx[3*n_cells + id] += 0.5*dtody*(dev_F_y[3*n_cells + ipojmo] - dev_F_y[3*n_cells + ipo])
                              + 0.5*dtodz*(dev_F_z[3*n_cells + ipokmo] - dev_F_z[3*n_cells + ipo]);
    dev_Q_Rx[4*n_cells + id] += 0.5*dtody*(dev_F_y[4*n_cells + ipojmo] - dev_F_y[4*n_cells + ipo])
                              + 0.5*dtodz*(dev_F_z[4*n_cells + ipokmo] - dev_F_z[4*n_cells + ipo]);
  }
  if (yid > n_ghost-3 && yid < ny-n_ghost+1 && xid > n_ghost-2 && xid < nx-n_ghost+1 && zid > n_ghost-2 && zid < nz-n_ghost+1)
  {
    // set the new y interface states
    // left
    int jpo = xid + (yid+1)*nx + zid*nx*ny;
    int imo = xid-1 + yid*nx + zid*nx*ny;
    int kmo = xid + yid*nx + (zid-1)*nx*ny;
    int jpoimo = xid-1 + (yid+1)*nx + zid*nx*ny;
    int jpokmo = xid + (yid+1)*nx + (zid-1)*nx*ny;
    dev_Q_Ly[            id] += 0.5*dtodz*(dev_F_z[            kmo] - dev_F_z[            id])
                              + 0.5*dtodx*(dev_F_x[            imo] - dev_F_x[            id]);
    dev_Q_Ly[  n_cells + id] += 0.5*dtodz*(dev_F_z[  n_cells + kmo] - dev_F_z[  n_cells + id])
                              + 0.5*dtodx*(dev_F_x[  n_cells + imo] - dev_F_x[  n_cells + id]);
    dev_Q_Ly[2*n_cells + id] += 0.5*dtodz*(dev_F_z[2*n_cells + kmo] - dev_F_z[2*n_cells + id])
                              + 0.5*dtodx*(dev_F_x[2*n_cells + imo] - dev_F_x[2*n_cells + id]);
    dev_Q_Ly[3*n_cells + id] += 0.5*dtodz*(dev_F_z[3*n_cells + kmo] - dev_F_z[3*n_cells + id])
                              + 0.5*dtodx*(dev_F_x[3*n_cells + imo] - dev_F_x[3*n_cells + id]);
    dev_Q_Ly[4*n_cells + id] += 0.5*dtodz*(dev_F_z[4*n_cells + kmo] - dev_F_z[4*n_cells + id])
                              + 0.5*dtodx*(dev_F_x[4*n_cells + imo] - dev_F_x[4*n_cells + id]);

    // right
    dev_Q_Ry[            id] += 0.5*dtodz*(dev_F_z[            jpokmo] - dev_F_z[            jpo])
                              + 0.5*dtodx*(dev_F_x[            jpoimo] - dev_F_x[            jpo]); 
    dev_Q_Ry[  n_cells + id] += 0.5*dtodz*(dev_F_z[  n_cells + jpokmo] - dev_F_z[  n_cells + jpo])
                              + 0.5*dtodx*(dev_F_x[  n_cells + jpoimo] - dev_F_x[  n_cells + jpo]);
    dev_Q_Ry[2*n_cells + id] += 0.5*dtodz*(dev_F_z[2*n_cells + jpokmo] - dev_F_z[2*n_cells + jpo])
                              + 0.5*dtodx*(dev_F_x[2*n_cells + jpoimo] - dev_F_x[2*n_cells + jpo]);
    dev_Q_Ry[3*n_cells + id] += 0.5*dtodz*(dev_F_z[3*n_cells + jpokmo] - dev_F_z[3*n_cells + jpo])
                              + 0.5*dtodx*(dev_F_x[3*n_cells + jpoimo] - dev_F_x[3*n_cells + jpo]);
    dev_Q_Ry[4*n_cells + id] += 0.5*dtodz*(dev_F_z[4*n_cells + jpokmo] - dev_F_z[4*n_cells + jpo])
                              + 0.5*dtodx*(dev_F_x[4*n_cells + jpoimo] - dev_F_x[4*n_cells + jpo]);    
  }
  if (zid > n_ghost-3 && zid < nz-n_ghost+1 && xid > n_ghost-2 && xid < nx-n_ghost+1 && yid > n_ghost-2 && yid < ny-n_ghost+1)
  {
    // set the new z interface states
    // left
    int kpo = xid + yid*nx + (zid+1)*nx*ny;
    int imo = xid-1 + yid*nx + zid*nx*ny;
    int jmo = xid + (yid-1)*nx + zid*nx*ny;
    int kpoimo = xid-1 + yid*nx + (zid+1)*nx*ny;
    int kpojmo = xid + (yid-1)*nx + (zid+1)*nx*ny;
    dev_Q_Lz[            id] += 0.5*dtodx*(dev_F_x[            imo] - dev_F_x[            id])
                              + 0.5*dtody*(dev_F_y[            jmo] - dev_F_y[            id]);
    dev_Q_Lz[  n_cells + id] += 0.5*dtodx*(dev_F_x[  n_cells + imo] - dev_F_x[  n_cells + id])
                              + 0.5*dtody*(dev_F_y[  n_cells + jmo] - dev_F_y[  n_cells + id]);
    dev_Q_Lz[2*n_cells + id] += 0.5*dtodx*(dev_F_x[2*n_cells + imo] - dev_F_x[2*n_cells + id])
                              + 0.5*dtody*(dev_F_y[2*n_cells + jmo] - dev_F_y[2*n_cells + id]);
    dev_Q_Lz[3*n_cells + id] += 0.5*dtodx*(dev_F_x[3*n_cells + imo] - dev_F_x[3*n_cells + id])
                              + 0.5*dtody*(dev_F_y[3*n_cells + jmo] - dev_F_y[3*n_cells + id]);
    dev_Q_Lz[4*n_cells + id] += 0.5*dtodx*(dev_F_x[4*n_cells + imo] - dev_F_x[4*n_cells + id])
                              + 0.5*dtody*(dev_F_y[4*n_cells + jmo] - dev_F_y[4*n_cells + id]);

    // right
    dev_Q_Rz[            id] += 0.5*dtodx*(dev_F_x[            kpoimo] - dev_F_x[            kpo])
                              + 0.5*dtody*(dev_F_y[            kpojmo] - dev_F_y[            kpo]); 
    dev_Q_Rz[  n_cells + id] += 0.5*dtodx*(dev_F_x[  n_cells + kpoimo] - dev_F_x[  n_cells + kpo])
                              + 0.5*dtody*(dev_F_y[  n_cells + kpojmo] - dev_F_y[  n_cells + kpo]);
    dev_Q_Rz[2*n_cells + id] += 0.5*dtodx*(dev_F_x[2*n_cells + kpoimo] - dev_F_x[2*n_cells + kpo])
                              + 0.5*dtody*(dev_F_y[2*n_cells + kpojmo] - dev_F_y[2*n_cells + kpo]);
    dev_Q_Rz[3*n_cells + id] += 0.5*dtodx*(dev_F_x[3*n_cells + kpoimo] - dev_F_x[3*n_cells + kpo])
                              + 0.5*dtody*(dev_F_y[3*n_cells + kpojmo] - dev_F_y[3*n_cells + kpo]);
    dev_Q_Rz[4*n_cells + id] += 0.5*dtodx*(dev_F_x[4*n_cells + kpoimo] - dev_F_x[4*n_cells + kpo])
                              + 0.5*dtody*(dev_F_y[4*n_cells + kpojmo] - dev_F_y[4*n_cells + kpo]);    
  }

}


__global__ void Update_Conserved_Variables_3D(Real *dev_conserved, Real *dev_F_x, Real *dev_F_y,  Real *dev_F_z,
                                              int nx, int ny, int nz, int n_ghost, Real dx, Real dy, Real dz, Real dt,
                                              Real gamma)
{
  int id, xid, yid, zid, n_cells;
  int imo, jmo, kmo;
  #ifdef DE
  Real d, d_inv, vx, vy, vz, P;
  Real vx_imo, vx_ipo, vy_jmo, vy_jpo, vz_kmo, vz_kpo;
  int ipo, jpo, kpo;
  #endif

  Real dtodx = dt/dx;
  Real dtody = dt/dy;
  Real dtodz = dt/dz;
  n_cells = nx*ny*nz;

  // get a global thread ID
  id = threadIdx.x + blockIdx.x * blockDim.x;
  zid = id / (nx*ny);
  yid = (id - zid*nx*ny) / nx;
  xid = id - zid*nx*ny - yid*nx;


  // threads corresponding to real cells do the calculation
  if (xid > n_ghost-1 && xid < nx-n_ghost && yid > n_ghost-1 && yid < ny-n_ghost && zid > n_ghost-1 && zid < nz-n_ghost)
  {
    imo = xid-1 + yid*nx + zid*nx*ny;
    jmo = xid + (yid-1)*nx + zid*nx*ny;
    kmo = xid + yid*nx + (zid-1)*nx*ny;
    #ifdef DE
    ipo = xid+1 + yid*nx + zid*nx*ny;
    jpo = xid + (yid+1)*nx + zid*nx*ny;
    kpo = xid + yid*nx + (zid+1)*nx*ny;
    d  =  dev_conserved[            id];
    d_inv = 1.0 / d;
    vx =  dev_conserved[1*n_cells + id] * d_inv;
    vy =  dev_conserved[2*n_cells + id] * d_inv;
    vz =  dev_conserved[3*n_cells + id] * d_inv;
    P  = (dev_conserved[4*n_cells + id] - 0.5*d*(vx*vx + vy*vy + vz*vz)) * (gamma - 1.0);
    vx_imo = dev_conserved[1*n_cells + imo] / dev_conserved[imo]; 
    vx_ipo = dev_conserved[1*n_cells + ipo] / dev_conserved[ipo]; 
    vy_jmo = dev_conserved[2*n_cells + jmo] / dev_conserved[jmo]; 
    vy_jpo = dev_conserved[2*n_cells + jpo] / dev_conserved[jpo]; 
    vz_kmo = dev_conserved[3*n_cells + kmo] / dev_conserved[kmo]; 
    vz_kpo = dev_conserved[3*n_cells + kpo] / dev_conserved[kpo]; 
    #endif

    // update the conserved variable array
    dev_conserved[            id] += dtodx * (dev_F_x[            imo] - dev_F_x[            id])
                                  +  dtody * (dev_F_y[            jmo] - dev_F_y[            id])
                                  +  dtodz * (dev_F_z[            kmo] - dev_F_z[            id]);
    dev_conserved[  n_cells + id] += dtodx * (dev_F_x[  n_cells + imo] - dev_F_x[  n_cells + id])
                                  +  dtody * (dev_F_y[  n_cells + jmo] - dev_F_y[  n_cells + id])
                                  +  dtodz * (dev_F_z[  n_cells + kmo] - dev_F_z[  n_cells + id]);
    dev_conserved[2*n_cells + id] += dtodx * (dev_F_x[2*n_cells + imo] - dev_F_x[2*n_cells + id])
                                  +  dtody * (dev_F_y[2*n_cells + jmo] - dev_F_y[2*n_cells + id])
                                  +  dtodz * (dev_F_z[2*n_cells + kmo] - dev_F_z[2*n_cells + id]);
    dev_conserved[3*n_cells + id] += dtodx * (dev_F_x[3*n_cells + imo] - dev_F_x[3*n_cells + id])
                                  +  dtody * (dev_F_y[3*n_cells + jmo] - dev_F_y[3*n_cells + id])
                                  +  dtodz * (dev_F_z[3*n_cells + kmo] - dev_F_z[3*n_cells + id]);
    dev_conserved[4*n_cells + id] += dtodx * (dev_F_x[4*n_cells + imo] - dev_F_x[4*n_cells + id])
                                  +  dtody * (dev_F_y[4*n_cells + jmo] - dev_F_y[4*n_cells + id])
                                  +  dtodz * (dev_F_z[4*n_cells + kmo] - dev_F_z[4*n_cells + id]);
    #ifdef DE
    dev_conserved[5*n_cells + id] += dtodx * (dev_F_x[5*n_cells + imo] - dev_F_x[5*n_cells + id])
                                  +  dtody * (dev_F_y[5*n_cells + jmo] - dev_F_y[5*n_cells + id])
                                  +  dtodz * (dev_F_z[5*n_cells + kmo] - dev_F_z[5*n_cells + id])
                                  +  0.5*P*(dtodx*(vx_imo-vx_ipo) + dtody*(vy_jmo-vy_jpo) + dtodz*(vz_kmo-vz_kpo));
    #endif

  }

}


__global__ void Sync_Energies_3D(Real *dev_conserved, int nx, int ny, int nz, int n_ghost, Real gamma)
{
  int id, xid, yid, zid, n_cells;
  Real d, d_inv, vx, vy, vz, P, E;
  Real ge1, ge2, Emax;
  int imo, ipo, jmo, jpo, kmo, kpo;
  n_cells = nx*ny*nz;

  // get a global thread ID
  id = threadIdx.x + blockIdx.x * blockDim.x;
  zid = id / (nx*ny);
  yid = (id - zid*nx*ny) / nx;
  xid = id - zid*nx*ny - yid*nx;

  imo = max(xid-1, n_ghost);
  imo = imo + yid*nx + zid*nx*ny;
  ipo = min(xid+1, nx-n_ghost-1);
  ipo = ipo + yid*nx + zid*nx*ny;
  jmo = max(yid-1, n_ghost);
  jmo = xid + jmo*nx + zid*nx*ny;
  jpo = min(yid+1, ny-n_ghost-1);
  jpo = xid + jpo*nx + zid*nx*ny;
  kmo = max(zid-1, n_ghost);
  kmo = xid + yid*nx + kmo*nx*ny;
  kpo = min(zid+1, nz-n_ghost-1);
  kpo = xid + yid*nx + kpo*nx*ny;

  // threads corresponding to real cells do the calculation
  if (xid > n_ghost-1 && xid < nx-n_ghost && yid > n_ghost-1 && yid < ny-n_ghost && zid > n_ghost-1 && zid < nz-n_ghost)
  {
    // every thread collects the conserved variables it needs from global memory
    d  =  dev_conserved[            id];
    d_inv = 1.0 / d;
    vx =  dev_conserved[1*n_cells + id] * d_inv;
    vy =  dev_conserved[2*n_cells + id] * d_inv;
    vz =  dev_conserved[3*n_cells + id] * d_inv;
    E  =  dev_conserved[4*n_cells + id];
    P  = (E - 0.5*d*(vx*vx + vy*vy + vz*vz)) * (gamma - 1.0);
    // separately tracked internal energy 
    ge1 =  dev_conserved[5*n_cells + id];
    // internal energy calculated from total energy
    ge2 = dev_conserved[4*n_cells + id] - 0.5*d*(vx*vx + vy*vy + vz*vz);
    // if the ratio of conservatively calculated internal energy to total energy
    // is greater than 1/1000, use the conservatively calculated internal energy
    // to do the internal energy update
    if (ge2/E > 0.001) {
      dev_conserved[5*n_cells + id] = ge2;
      ge1 = ge2;
    }     
    //find the max nearby total energy 
    Emax = fmax(dev_conserved[4*n_cells + imo], E);
    Emax = fmax(Emax, dev_conserved[4*n_cells + ipo]);
    Emax = fmax(Emax, dev_conserved[4*n_cells + jmo]);
    Emax = fmax(Emax, dev_conserved[4*n_cells + jpo]);
    Emax = fmax(Emax, dev_conserved[4*n_cells + kmo]);
    Emax = fmax(Emax, dev_conserved[4*n_cells + kpo]);
    // if the ratio of conservatively calculated internal energy to max nearby total energy
    // is greater than 1/10, continue to use the conservatively calculated internal energy 
    if (ge2/Emax > 0.1) {
      dev_conserved[5*n_cells + id] = ge2;
    }
    // sync the total energy with the internal energy 
    else {
      dev_conserved[4*n_cells + id] += ge1 - ge2;
    }
    // recalculate the pressure 
    P = (dev_conserved[4*n_cells + id] - 0.5*d*(vx*vx + vy*vy + vz*vz)) * (gamma - 1.0);    
    if (P < 0.0) printf("%3d %3d %3d Negative pressure after internal energy sync. %f %f %f\n", xid, yid, zid, P/(gamma-1.0), ge1, ge2);    
  }
}


__global__ void Calc_dt_3D(Real *dev_conserved, int nx, int ny, int nz, int n_ghost, Real dx, Real dy, Real dz, Real *dti_array, Real gamma)
{
  __shared__ Real max_dti[TPB];

  Real d, d_inv, vx, vy, vz, P, cs;
  int id, xid, yid, zid, n_cells;
  int tid;

  n_cells = nx*ny*nz;

  // get a global thread ID
  id = threadIdx.x + blockIdx.x * blockDim.x;
  zid = id / (nx*ny);
  yid = (id - zid*nx*ny) / nx;
  xid = id - zid*nx*ny - yid*nx;
  // and a thread id within the block  
  tid = threadIdx.x;

  // set shared memory to 0
  max_dti[tid] = 0;
  __syncthreads();

  // threads corresponding to real cells do the calculation
  if (xid > n_ghost-1 && xid < nx-n_ghost && yid > n_ghost-1 && yid < ny-n_ghost && zid > n_ghost-1 && zid < nz-n_ghost)
  {
    // every thread collects the conserved variables it needs from global memory
    d  =  dev_conserved[            id];
    d_inv = 1.0 / d;
    vx =  dev_conserved[1*n_cells + id] * d_inv;
    vy =  dev_conserved[2*n_cells + id] * d_inv;
    vz =  dev_conserved[3*n_cells + id] * d_inv;
    P  = (dev_conserved[4*n_cells + id] - 0.5*d*(vx*vx + vy*vy + vz*vz)) * (gamma - 1.0);
    cs = sqrt(d_inv * gamma * P);
    max_dti[tid] = fmax((fabs(vx)+cs)/dx, (fabs(vy)+cs)/dy);
    max_dti[tid] = fmax(max_dti[tid], (fabs(vz)+cs)/dz);
    //max_dti[tid] = (fabs(vx)+cs)/dx + (fabs(vy)+cs)/dy + (fabs(vz)+cs)/dz;
  }
  __syncthreads();
  
  // do the reduction in shared memory (find the max inverse timestep in the block)
  for (unsigned int s=1; s<blockDim.x; s*=2) {
    if (tid % (2*s) == 0) {
      max_dti[tid] = fmax(max_dti[tid], max_dti[tid + s]);
    }
    __syncthreads();
  }

  // write the result for this block to global memory
  if (tid == 0) dti_array[blockIdx.x] = max_dti[0];

}


#endif //CUDA
