import GPUArrays: allowscalar, @allowscalar


## unified memory indexing

const coherent = Ref(true)

# toggle coherency based on API calls
function set_coherency(apicall)
  # TODO: whitelist
  coherent[] = false
  return
end

function force_coherency()
  # TODO: not on newer hardware with certain flags

  if CUDAdrv.apicall_hook[] !== set_coherency
    # we didn't have our API call hook in place, all bets are off
    coherent[] = false
  end

  if !coherent[]
    CUDAdrv.synchronize()
    coherent[] = true
  elseif CUDAdrv.apicall_hook[] === nothing
    # nobody else is hooking for CUDA API calls, so we can safely install ours
    CUDAdrv.apicall_hook[] = set_coherency
  end
end

function GPUArrays._getindex(xs::CuArray{T}, i::Integer) where T
  buf = buffer(xs)
  if isa(buf, Mem.UnifiedBuffer)
    force_coherency()
    ptr = convert(Ptr{T}, buffer(xs))
    unsafe_load(ptr, i)
  else
    val = Array{T}(undef)
    copyto!(val, 1, xs, i, 1)
    val[]
  end
end

function GPUArrays._setindex!(xs::CuArray{T}, v::T, i::Integer) where T
  buf = buffer(xs)
  if isa(buf, Mem.UnifiedBuffer)
    force_coherency()
    ptr = convert(Ptr{T}, buffer(xs))
    unsafe_store!(ptr, v, i)
  else
    copyto!(xs, i, T[v], 1, 1)
  end
end


## logical indexing

Base.getindex(xs::CuArray, bools::AbstractArray{Bool}) = getindex(xs, CuArray(bools))

function Base.getindex(xs::CuArray{T}, bools::CuArray{Bool}) where {T}
  bools = reshape(bools, prod(size(bools)))
  indices = cumsum(bools)  # unique indices for elements that are true

  n = GPUArrays._getindex(indices, length(indices))  # number that are true
  ys = CuArray{T}(undef, n)

  if n > 0
    function kernel(ys::CuDeviceArray{T}, xs::CuDeviceArray{T}, bools, indices)
        i = threadIdx().x + (blockIdx().x - 1) * blockDim().x

        if i <= length(xs) && bools[i]
            b = indices[i]   # new position
            ys[b] = xs[i]

        end

        return
    end

    function configurator(kernel)
        fun = kernel.fun
        config = launch_configuration(fun)
        blocks = cld(length(indices), config.threads)

        return (threads=config.threads, blocks=blocks)
    end

    @cuda config=configurator kernel(ys, xs, bools, indices)
  end

  unsafe_free!(indices)

  return ys
end


## findall

function Base.findall(bools::CuArray{Bool})
    indices = cumsum(bools)

    n = _getindex(indices, length(indices))
    ys = CuArray{Int}(undef, n)

    if n > 0
        num_threads = min(n, 256)
        num_blocks = ceil(Int, length(indices) / num_threads)

        function kernel(ys::CuDeviceArray{Int}, bools, indices)
            i = threadIdx().x + (blockIdx().x - 1) * blockDim().x

            if i <= length(bools) && bools[i]
                b = indices[i]   # new position
                ys[b] = i

            end

            return
        end

        function configurator(kernel)
            fun = kernel.fun
            config = launch_configuration(fun)
            blocks = cld(length(indices), config.threads)

            return (threads=config.threads, blocks=blocks)
        end

        @cuda config=configurator kernel(ys, bools, indices)
    end

    unsafe_free!(indices)

    return ys
end

function Base.findall(f::Function, A::CuArray)
    bools = map(f, A)
    ys = findall(bools)
    unsafe_free!(bools)
    return ys
end
