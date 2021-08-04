#include"gpu.hpp"
#include"global.h"
#include"global_cuda.h"


__device__ void PackBuffers3D(Real * buffer, Real * c_head, int isize, int jsize, int ksize, int nx, int ny, int idxoffset, int offset, int n_fields, int n_cells)
{
  int id,i,j,k,idx,ii;
  id = threadIdx.x + blockIdx.x * blockDim.x;
  if (id >= offset){
    return;
  }
  k = id/(isize*jsize);
  j = (id - k*isize*jsize)/isize;
  i = id - k*isize*jsize - j*isize;
  idx  = i + (j+k*ny)*nx + idxoffset;
  //(i+ioffset) + (j+joffset)*H.nx + (k+koffset)*H.nx*H.ny;
  // gidx = id 
  //gidx = i+(j+k*jsize)*isize; 
  //gidx = i + j*isize + k*ijsize;//i+(j+k*jsize)*isize
  for (ii=0; ii<n_fields; ii++) {
    *(buffer + id + ii*offset) = c_head[idx + ii*n_cells]; 
  }
  
}
