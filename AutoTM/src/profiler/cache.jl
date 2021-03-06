# TODO: Hold on to constant parameters such as padding and stride for Convolutions
"""
$(SIGNATURES)

Extract the kernel parameters from `node`.
"""
params(backend::nGraph.Backend{nGraph.CPU}, node::nGraph.NodeLike) = CPUKernelParams(node)
params(backend::nGraph.Backend{nGraph.GPU}, node::nGraph.NodeLike) = GPUKernelParams(node)
params(backend, node::XNode) = params(backend, unx(node))

# Cache object for recording seen kernels.
"""
    CPUKernelParams

Parameter set for nGraph CPU Kernels.

$(METHODLIST)

$(FIELDS)
"""
struct CPUKernelParams{IS, OS, IT, OT, NIF}
    "The description of the op."
    description::String

    # IO Sizes
    "Sizes of the input tensors."
    input_sizes::IS
    "Sizes of the output tensors."
    output_sizes::OS
    "Element types of the input tensors."
    input_types::IT
    "Element types of the output tensors."
    output_types::OT

    # MKLDNN Formats
    "Flag indicating if node is a `mkldnn` op."
    ismkl::Bool
    "Enumj values of the tensor mkldnn input formats."
    input_formats::NTuple{NIF, Int64}
end

# Get the MKL format string for an op
mkldnn_string(x) = last(split(nGraph.Lib.get_mkldnn_string(x), ":"))

function CPUKernelParams(node::nGraph.NodeLike)
    description = nGraph.description(node)

    # Input processing
    num_inputs = nGraph.get_input_size(node)

    input_sizes = ntuple(x -> nGraph.get_input_shape(node, x), num_inputs)
    input_types = ntuple(x -> nGraph.get_input_element_type(node, x), num_inputs)

    # Only
    ismkl = nGraph.is_mkldnn(node)
    input_formats = ntuple(
        # At the moment, still forwarding to nGraph.Lib.
        x -> nGraph.Lib.get_input_format_int(node.ptr, convert(UInt, x-1)),
        num_inputs
    )

    # output processing
    num_outputs = nGraph.get_output_size(node)
    output_sizes = ntuple(x -> nGraph.get_output_shape(node, x), num_outputs)
    output_types = ntuple(x -> nGraph.get_output_element_type(node, x), num_outputs)

    return CPUKernelParams(
        description,
        input_sizes,
        output_sizes,
        input_types,
        output_types,
        ismkl,
        input_formats,
    )
end

## GPU
"""
    GPUKernelParams

Parameters for a GPU Kernel.

$(METHODLIST)

$(FIELDS)
"""
struct GPUKernelParams{IS, OS, IT, OT}
    "The description of the op."
    description::String

    # IO Sizes
    "Sizes of the input tensors."
    input_sizes::IS
    "Sizes of the output tensors."
    output_sizes::OS
    "Element types of the input tensors."
    input_types::IT
    "Element types of the output tensors."
    output_types::OT
end

function GPUKernelParams(node::nGraph.NodeLike)
    description = nGraph.description(node)

    # Input processing
    num_inputs = nGraph.get_input_size(node)
    input_sizes = ntuple(x -> nGraph.get_input_shape(node, x), num_inputs)
    input_types = ntuple(x -> nGraph.get_input_element_type(node, x), num_inputs)

    # output processing
    num_outputs = nGraph.get_output_size(node)
    output_sizes = ntuple(x -> nGraph.get_output_shape(node, x), num_outputs)
    output_types = ntuple(x -> nGraph.get_output_element_type(node, x), num_outputs)

    return GPUKernelParams(
        description,
        input_sizes,
        output_sizes,
        input_types,
        output_types,
    )
end

#####
##### Caches
#####

abstract type AbstractKernelCache end

Base.getindex(cache::AbstractKernelCache, args...) = getindex(cache.cache, args...)
Base.setindex!(cache::AbstractKernelCache, args...) = setindex!(cache.cache, args...)
Base.haskey(cache::AbstractKernelCache, args...) = haskey(cache.cache, args...)
Base.delete!(cache::AbstractKernelCache, args...) = delete!(cache.cache, args...)

# NOTE: Keeping caches as separate types rather than parametric to be backwards compatible
# with older serialized objects.
struct CPUKernelCache <: AbstractKernelCache
    file::String
    cache::Dict{Tuple{CPUKernelParams, IOConfig}, Float64}
end

struct GPUKernelCache <: AbstractKernelCache
    file::String
    cache::Dict{Tuple{GPUKernelParams, IOConfig}, Union{Float64, Vector{CUDNNAlgorithm}}}
end

# Method to determine if we can select the algorithm for this kernel.
can_select_algo(c::GPUKernelCache, p::GPUKernelParams) = _cs(c.cache[p])

CPUKernelCache(file; kw...) = _make_cache(CPUKernelCache, file; kw...)::CPUKernelCache
GPUKernelCache(file; kw...) = _make_cache(GPUKernelCache, file; kw...)::GPUKernelCache

function _make_cache(::Type{T}, file; force_new = false) where {T}
    # If the cache path already exists, just return the existing object.
    # The type assertion for the function will make sure we don't return something weird.
    if (force_new == false) && ispath(file)
        # Deserialize the file.
        cache_db = deserialize(file)

        # Check if we have a key for the current environment context
        # TODO: Don't really need this for the GPU ...
        ctx = _env_context()
        haskey(cache_db, ctx) && return cache_db[ctx]::T
    end

    # Otherwise, create the object.
    return T(
        file,
        last(fieldtypes(T))()
    )
end

function save(cache::AbstractKernelCache)
    # Make the directory for this cache if needed.
    dir = dirname(cache.file)
    ispath(dir) || mkdir(dir)

    # Deserialize the existing cache.
    ctx = _env_context()
    if ispath(cache.file)
        cache_db = deserialize(cache.file)::Dict
        cache_db[ctx] = cache
    else
        cache_db = Dict(ctx => cache)
    end

    # Serialize to a temporary file first
    # Then swap with the original cache.
    #
    # This ensures that if we're interrupted during serialization (which does happen)
    # we don't corrupt the original cache.
    path = tempname()
    open(path; write = true) do io
        serialize(io, cache_db)
    end

    mv(path, cache.file; force = true)
end

