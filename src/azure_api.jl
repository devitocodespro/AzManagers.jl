const RETRYABLE_HTTP_ERRORS = (
    409,  # Conflict
    429,  # Too many requests
    500)  # Internal server error

function isretryable(e::HTTP.StatusError)
    e.status ∈ RETRYABLE_HTTP_ERRORS && (return true)
    false
end
isretryable(e::Base.IOError) = true
isretryable(e::HTTP.Exceptions.ConnectError) = true
isretryable(e::HTTP.Exceptions.HTTPError) = true
isretryable(e::HTTP.Exceptions.RequestError) = true
isretryable(e::HTTP.Exceptions.TimeoutError) = true
isretryable(e::Base.EOFError) = true
isretryable(e::Sockets.DNSError) = true
isretryable(e) = false

status(e::HTTP.StatusError) = e.status
status(e) = 999

function retrywarn(i, retries, seconds, e)
    if isa(e, HTTP.ExceptionRequest.StatusError)
        @debug "$(e.status): $(String(e.response.body)), retry $i of $retries, retrying in $seconds seconds"
        if e.status == 429
            remaining_resource_header = nothing
            for header in e.response.headers
                if header[1] == "x-ms-ratelimit-remaining-resource"
                    remaining_resource_header = header
                    break
                end
            end
            @warn "The Azure service is throttling the request, asking to retry after $seconds seconds. Quota information:" remaining_resource_header[2]
        elseif e.status == 500
            body = JSON.parse(String(e.response.body))
            errorcode = get(get(body, "error", Dict()), "code", "")
            @warn "errorcode: $errorcode, retry $i, retrying in $seconds seconds"
        elseif e.status == 409
            body = JSON.parse(String(e.response.body))
            errorcode = get(get(body, "error", Dict()), "code", "")
            errormessage = get(get(body, "error", Dict()), "message", "")
            @warn "($errorcode): $errormessage; retry $i of $retries, retrying in $seconds seconds"
        else
            @warn "status=$(e.status): $(String(e.response.body)), retry $i of $retries, retrying in $seconds seconds"
        end
    else
        @warn "warn: $(typeof(e)) -- retry $i, retrying in $seconds seconds"
        logerror(e, Logging.Debug)
    end
end

macro retry(retries, ex::Expr)
    quote
        result = nothing
        for i = 0:$(esc(retries))
            try
                result = $(esc(ex))
                break
            catch e
                (i < $(esc(retries)) && isretryable(e)) || throw(e)
                maximum_backoff = 256
                seconds = min(2.0^(i - 1), maximum_backoff) + rand()
                if status(e) ∈ (429, 500)
                    for header in e.response.headers
                        if lowercase(header[1]) == "retry-after"
                            seconds = parse(Int, header[2]) + rand()
                            break
                        end
                    end
                end
                retrywarn(i, $(esc(retries)), seconds, e)
                sleep(seconds)
            end
        end
        result
    end
end

function azrequest(rtype, verbose, url, headers, body=nothing)
    if contains(url, "virtualMachineScaleSets")
        manager = azmanager()
        if isdefined(manager, :scaleset_request_counter)
            manager.scaleset_request_counter += 1
        else
            manager.scaleset_request_counter = 1
        end
    end

    options = (retry=false, status_exception=false)
    if body === nothing
        response = HTTP.request(rtype, url, headers; verbose=verbose, options...)
    else
        response = HTTP.request(rtype, url, headers, body; verbose=verbose, options...)
    end

    if response.status >= 300
        throw(HTTP.Exceptions.StatusError(
            response.status,
            response.request.method,
            response.request.target,
            response))
    end

    response
end

function scaleset_request_counter()
    manager = azmanager()
    if isdefined(manager, :scaleset_request_counter)
        return manager.scaleset_request_counter
    else
        return 1
    end
end

function remaining_resource(response)
    remaining_resource_header = ""
    for header in response.headers
        if header[1] == "x-ms-ratelimit-remaining-resource"
            remaining_resource_header = header[2]
        end
    end
    remaining_resource_header
end

