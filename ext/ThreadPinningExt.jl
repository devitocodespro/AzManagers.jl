module ThreadPinningExt

using AzManagers, ThreadPinning

function AzManagers._pin_julia_threads_impl(cpu_set::Vector{Int})
    isempty(cpu_set) && return false
    ThreadPinning.pinthreads(cpu_set)
    true
end

end
