!
!
! Copyright 2017 Tom Deakin, University of Bristol
!
! This file is part of mega-stream.
!
! mega-stream is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! mega-stream is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with mega-stream.  If not, see <http://www.gnu.org/licenses/>.
!
! This aims to investigate the limiting factor for a simple kernel, in particular
! where bandwidth limits not to be reached, and latency becomes a dominating factor.

!
program megasweep

  ! MEGA-SWEEP adds a KBA sweep along with the MPI communication to the MEGA-STREAM kernel

  use mpi

  implicit none

  ! MPI variables
  integer :: mpi_thread_level
  integer :: ierr
  integer :: rank, nprocs
  integer :: comm


  ! Problem sizes
  integer :: nang, ng ! angles and groups
  integer :: nx, ny   ! global mesh size
  integer :: lnx      ! local mesh size
  integer :: chunk    ! y chunk size
  integer :: nsweeps  ! sweep direction
  integer :: ntimes   ! number of times

  ! Arrays
  real(kind=8), dimension(:,:,:,:,:), pointer :: aflux0, aflux1 ! angular flux
  real(kind=8), dimension(:,:,:,:,:), pointer :: aflux_ptr      ! for pointer swap
  real(kind=8), dimension(:,:,:), allocatable :: sflux          ! scalar flux
  real(kind=8), dimension(:), allocatable :: mu, eta            ! angular cosines
  real(kind=8), dimension(:,:,:), allocatable :: psii, psij     ! edge angular flux
  real(kind=8), dimension(:), allocatable :: w                  ! scalar flux weights
  real(kind=8) :: v                                             ! time constant

  ! Timers
  real(kind=8) :: start_time
  real(kind=8), dimension(:), allocatable :: time

  ! Local variables
  integer :: t
  real(kind=8) :: moved ! model of data movement

  call MPI_Init_thread(MPI_THREAD_FUNNELED, mpi_thread_level, ierr)
  if (mpi_thread_level.LT.MPI_THREAD_FUNNELED) then
    print *, "Cannot provide MPI thread level"
    stop
  end if

  comm = MPI_COMM_WORLD
  call MPI_Comm_rank(comm, rank, ierr)
  call MPI_Comm_size(comm, nprocs, ierr)

  ! Set problem sizes
  nx = 128
  ny = 128
  ng = 16
  nang = 16
  nsweeps = 4
  chunk = 1
  ntimes = 20

  ! Decompose in x-dimension
  if (mod(nx,nprocs).NE.0) then
    if (rank.EQ.0) then
      print *, "Number of ranks must divide nx"
    end if
    stop
  end if
  lnx = nx / nprocs

  ! Allocate data
  allocate(aflux0(nang,lnx,ny,nsweeps,ng))
  allocate(aflux1(nang,lnx,ny,nsweeps,ng))
  allocate(sflux(lnx,ny,ng))
  allocate(mu(nang))
  allocate(eta(nang))
  allocate(psii(nang,chunk,ng))
  allocate(psij(nang,lnx,ng))
  allocate(w(nang))

  ! Initilise data
  aflux0 = 1.0_8
  aflux1 = 0.0_8
  sflux = 0.0_8
  mu = 0.33_8
  eta = 0.66_8
  psii = 0.0_8
  psij = 0.0_8
  w = 0.4_8
  v = 0.1_8

  ! Allocate timers
  allocate(time(ntimes))

  if (rank.EQ.0) then
    print *, "MEGA-SWEEP!"
    print *
    print *, "Num. procs:", nprocs
    print *, "Mesh size:", nx, ny
    print *, "Angles:", nang
    print *, "Groups:", ng
    print *, "Flux size/rank (MB):", (nang*lnx*ny*nsweeps*ng*8)/2**20
    print *
  end if


  do t = 1, ntimes

    start_time = MPI_Wtime()

    call sweeper(nang,lnx,ny,ng,nsweeps,chunk, &
                 aflux0,aflux1,sflux,          &
                 psii,psij,                    &
                 mu,eta,w,v)

    ! Swap pointers
    aflux_ptr => aflux0
    aflux0 => aflux1
    aflux1 => aflux_ptr

    time(t) = MPI_Wtime() - start_time

  end do

  ! Model data movement
  moved = 8 * 1.0E-6 * (          &
          nang*nx*ny*ng*nsweeps + & ! read aflux0
          nang*nx*ny*ng*nsweeps + & ! write aflux1
          nang + nang +           & ! read mu and eta
          2.0*nang*ny*ng +        & ! read and write psii
          2.0*nang*nx*ng +        & ! read and write psij
          2.0*nx*ny*ng)             ! read and write sflux


  if (rank.EQ.0) then
    print *, "Runtime (s):", sum(time)
    print *, "Fastest sweep (s):", minval(time(2:))
    print *, "Bandwidth (MB/s):", moved/minval(time(2:))
  end if

  ! Free data
  deallocate(aflux0, aflux1)
  deallocate(sflux)
  deallocate(mu, eta)
  deallocate(psii, psij)
  deallocate(w)
  deallocate(time)

  call MPI_Finalize(ierr)

end program

! Sweep kernel
subroutine sweeper(nang,nx,ny,ng,nsweeps,chunk, &
                 aflux0,aflux1,sflux,           &
                 psii,psij,                     &
                 mu,eta,                        &
                 w,v)

  implicit none

  integer :: nang, nx, ny, ng, nsweeps, chunk
  real(kind=8) :: aflux0(nang,nx,ny,nsweeps,ng)
  real(kind=8) :: aflux1(nang,nx,ny,nsweeps,ng)
  real(kind=8) :: sflux(nx,ny,ng)
  real(kind=8) :: psii(nang,chunk,ng)
  real(kind=8) :: psij(nang,nx,ng)
  real(kind=8) :: mu(nang)
  real(kind=8) :: eta(nang)
  real(kind=8) :: w(nang)
  real(kind=8) :: v

  integer :: a, i, j, g, cj, sweep
  integer :: xdir, ydir
  real(kind=8) :: psi

  sweep = 1

  do j = 1, ny, chunk
    do g = 1, ng
      do cj = 1, chunk
        do i = 1, nx
          do a = 1, nang
            ! Calculate angular flux
            psi = mu(a)*psii(a,cj,g) + eta(a)*psij(a,i,g) + v*aflux0(a,i,j,sweep,g)

            ! Outgoing diamond difference
            psii(a,cj,g) = 2.0_8*psi - psii(a,cj,g)
            psij(a,i,g) = 2.0_8*psi - psij(a,i,g)
            aflux1(a,i,j,sweep,g) = 2.0_8*psi - aflux0(a,i,j,sweep,g)

            ! Reduction
            sflux(i,j,g) = sflux(i,j,g) + psi*w(a)

          end do ! angle loop
        end do ! x loop
      end do ! y chunk loop
    end do ! group loop

  end do ! chunk loop

end subroutine sweeper

