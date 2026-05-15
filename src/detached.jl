const DETACHED_ROUTER = HTTP.Router()

mutable struct DetachedServiceState
    jobs::Dict{String,Dict{String,Any}}
    vm::Base.RefValue{Dict{String,String}}
end

const DETACHED_STATE = DetachedServiceState(
    Dict{String,Dict{String,Any}}(),
    Ref(Dict{String,String}()))
const DETACHED_JOBS = DETACHED_STATE.jobs
const DETACHED_VM = DETACHED_STATE.vm

