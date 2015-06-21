

# some basic definitions for generic matches

execute(k::Config, m, s, i) = error("$m did not expect to be called with state $s")
success(k::Config, m, s, t, i, r) = error("$m did not expect to receive state $s, result $r")
failure(k::Config, m, s) = error("$m did not expect to receive state $s, failure")

execute(k::Config, m::Matcher, s::Dirty, i) = FAILURE



# many matchers delegate to a child, making only slight modifications.
# we can describe the default behaviour just once, here.
# child matchers then need to implement (1) state creation (typically on 
# response) and (2) anything unusual (ie what the matcher actually does)

# assume this has a matcher field
abstract Delegate<:Matcher

# assume this has a state field
abstract DelegateState<:State

execute(k::Config, m::Delegate, s::Clean, i) = Execute(m, s, m.matcher, CLEAN, i)

execute(k::Config, m::Delegate, s::DelegateState, i) = Execute(m, s, m.matcher, s.state, i)

# this avoids re-calling child on backtracking on failure
failure(k::Config, m::Delegate, s) = FAILURE



# various weird things for completeness

@auto_hash_equals type Epsilon<:Matcher
    name::Symbol
    Epsilon() = new(:Epsilon)
end

execute(k::Config, m::Epsilon, s::Clean, i) = Success(DIRTY, i, EMPTY)


@auto_hash_equals type Insert<:Matcher
    name::Symbol
    text
    Insert(text) = new(:Insert, text)
end

execute(k::Config, m::Insert, s::Clean, i) = Success(DIRTY, i, Any[m.text])


@auto_hash_equals immutable Dot<:Matcher 
    name::Symbol
    Dot() = new(:Dot)
end

function execute(k::Config, m::Dot, s::Clean, i)
    if done(k.source, i)
        FAILURE
    else
        c, i = next(k.source, i)
        Success(DIRTY, i, Any[c])
    end
end


@auto_hash_equals immutable Fail<:Matcher
    name::Symbol
    Fail() = new(:Fail)
end

execute(k::Config, m::Fail, s::Clean, i) = FAILURE



# evaluate the sub-matcher, but replace the result with EMPTY

@auto_hash_equals type Drop<:Delegate
    name::Symbol
    matcher::Matcher
    Drop(matcher) = new(:Drop, matcher)
end

@auto_hash_equals immutable DropState<:DelegateState
    state::State
end

success(k::Config, m::Drop, s, t, i, r::Value) = Success(DropState(t), i, EMPTY)



# exact match

@auto_hash_equals type Equal<:Matcher
    name::Symbol
    string
    Equal(string) = new(:Equal, string)
end

always_print(::Equal) = true
function print_field(m::Equal, ::Type{Val{:string}})
    if isa(m.string, AbstractString)
        "\"$(m.string)\""
    else
        :string
    end
end

function execute(k::Config, m::Equal, s::Clean, i)
    for x in m.string
        if done(k.source, i)
            return FAILURE
        end
        y, i = next(k.source, i)
        if x != y
            return FAILURE
        end
    end
    Success(DIRTY, i, Any[m.string])
end



# repetition

# in both cases (Depth and Breadth) we perform a tree search of all
# possible states (limited by the maximum number of matches), yielding
# when we have a result within the lo/hi range.

abstract Repeat_<:Matcher   # _ to avoid conflict with function in 0.3

ALL = typemax(Int)

abstract RepeatState<:State

function Repeat(m::Matcher, lo, hi; flatten=true, greedy=true)
    if greedy
        Depth(m, lo, hi; flatten=flatten)
    else
        Breadth(m, lo, hi; flatten=flatten)
    end
end
Repeat(m::Matcher, lo; flatten=true, greedy=true) = Repeat(m, lo, lo; flatten=flatten, greedy=greedy)
Repeat(m::Matcher; flatten=true, greedy=true) = Repeat(m, 0, ALL; flatten=flatten, greedy=greedy)

print_field(m::Repeat_, ::Type{Val{:lo}}) = "lo=$(m.lo)"
print_field(m::Repeat_, ::Type{Val{:hi}}) = "hi=$(m.hi)"
print_field(m::Repeat_, ::Type{Val{:flatten}}) = "flatten=$(m.flatten)"

# depth-first (greedy) state and logic

@auto_hash_equals type Depth<:Repeat_
    name::Symbol
    matcher::Matcher
    lo::Integer
    hi::Integer
    flatten::Bool
    Depth(m, lo, hi; flatten=true) = new(:Depth, m, lo, hi, flatten)
end

# greedy matching is effectively depth first traversal of a tree where:
# * performing an additional match is moving down to a new level 
# * performaing an alternate match (backtrack+match) moves across
# the traversal requires a stack.  the DepthState instances below all
# store that stack - actually three of them.  the results stack is 
# unusual / neat in that it is also what we need to return.

# unfortunately, things are a little more complex, because it's not just
# DFS, but also post-order.  which means there's some extra messing around
# so that the node ordering is correct.

abstract DepthState<:RepeatState

# an arbitrary iter to pass to a state where it's not needed (typically from
# failure)
arbitrary(s::DepthState) = s.iters[1]

@auto_hash_equals type Slurp<:DepthState
    # there's a mismatch in lengths here because the empty results is
    # associated with an iter and state
    results::Array{Value,1} # accumulated.  starts []
    iters::Array{Any,1}     # at the end of the result.  starts [i].
    states::Array{State,1}  # at the end of the result.  starts [DIRTY],
                            # since [] at i is returned last.
end

@auto_hash_equals type DepthYield<:DepthState
    results::Array{Value,1}
    iters::Array{Any,1}
    states::Array{State,1}
end

@auto_hash_equals type Backtrack<:DepthState
    results::Array{Value,1}
    iters::Array{Any,1}
    states::Array{State,1}
end

# when first called, create base state and make internal transition

execute(k::Config, m::Depth, s::Clean, i) = execute(k, m, Slurp(Array(Value, 0), [i], State[DIRTY]), i)

# repeat matching until at bottom of this branch (or maximum depth)

max_depth(m::Depth, results) = m.hi == length(results)

function execute(k::Config, m::Depth, s::Slurp, i)
    if max_depth(m, s.results)
        execute(k, m, DepthYield(s.results, s.iters, s.states), i)
    else
        Execute(m, s, m.matcher, CLEAN, i)
    end
end

function success(k::Config, m::Depth, s::Slurp, t, i, r::Value)
    results = Value[s.results..., r]
    iters = vcat(s.iters, i)
    states = vcat(s.states, t)
    if max_depth(m, results)
        execute(k, m, DepthYield(results, iters, states), i)
    else
        Execute(m, Slurp(results, iters, states), m.matcher, CLEAN, i)
    end
end

function failure(k::Config, m::Depth, s::Slurp)
    # the iter passed on is arbitrary and unused
    execute(k, m, DepthYield(s.results, s.iters, s.states), arbitrary(s))
end

# yield a result and set state to backtrack

function execute(k::Config, m::Depth, s::DepthYield, unused)
    n = length(s.results)
    if n >= m.lo
        if m.flatten
            Success(Backtrack(s.results, s.iters, s.states), s.iters[end], flatten(s.results))
        else
            # Array{Value,1} -> Value
            Success(Backtrack(s.results, s.iters, s.states), s.iters[end], Any[s.results;])
        end
    else
        # we need to continue searching in case there's some other weird
        # case that gets us back into valid matches
        execute(k, m, Backtrack(s.results, s.iters, s.states), arbitrary(s))
    end
end

# backtrack once and then move down again if possible.  we cannot repeat a
# path because we always advance child state.

function execute(k::Config, m::Depth, s::Backtrack, unused)
    if length(s.iters) == 1  # we've exhausted the search space
        FAILURE
    else
        # we need the iter from *before* the result
        Execute(m, Backtrack(s.results[1:end-1], s.iters[1:end-1], s.states[1:end-1]), m.matcher, s.states[end], s.iters[end-1])
    end
end

# backtrack succeeded so move down
success(k::Config, m::Depth, s::Backtrack, t, i, r::Value) = execute(k, m, Slurp(Value[s.results..., r], vcat(s.iters, i), vcat(s.states, t)), i)

# we couldn't move down, so yield this point
failure(k::Config, m::Depth, s::Backtrack) = execute(k, m, DepthYield(s.results, s.iters, s.states), arbitrary(s))



# breadth-first specific state and logic

@auto_hash_equals type Breadth<:Repeat_
    name::Symbol
    matcher::Matcher
    lo::Integer
    hi::Integer
    flatten::Bool
    Breadth(m, lo, hi; flatten=true) = new(:Breadth, m, lo, hi, flatten)
end

# minimal matching is effectively breadth first traversal of a tree where:
# * performing an additional match is moving down to a new level 
# * performaing an alternate match (backtrack+match) moves across
# the traversal requires a queue.  unfortunately, unlike with greedy,
# that means we need to store the entire result for each node.

# on the other hand, because the results are pre-order, the logic is simpler
# than for the greedy match (wikipedia calls this "level order" so my 
# terminology may be wrong).

@auto_hash_equals type Entry
    iter
    state::State
    results::Array{Value,1}
end

abstract BreadthState<:RepeatState

arbitrary(s::BreadthState) = s.start

@auto_hash_equals type Grow<:BreadthState
    start  # initial iter
    queue::Array{Entry,1}  # this has to be type for caching
end

@auto_hash_equals type BreadthYield<:BreadthState
    start  # initial iter
    queue::Array{Entry,1}  # this has to be immutable for caching
end

# when first called, create base state and make internal transition

execute(k::Config, m::Breadth, s::Clean, i) = execute(k, m, BreadthYield(i, Entry[Entry(i, CLEAN, [])]), i)

# yield the top state

function execute(k::Config, m::Breadth, s::BreadthYield, unused)
    q = s.queue[1]
    n = length(q.results)
    if n >= m.lo
        if m.flatten
            Success(Grow(s.start, s.queue), q.iter, flatten(q.results))
        else
            # Array{Value,1} -> Value
            Success(Grow(s.start, s.queue), q.iter, Any[q.results;])
        end
    else
        execute(k, m, Grow(s.start, s.queue), unused)
    end
end

# add the next row

function execute(k::Config, m::Breadth, s::Grow, unused)
    if length(s.queue[1].results) > m.hi
        FAILURE
    else
        Execute(m, s, m.matcher, CLEAN, s.queue[1].iter)
    end
end

success(k::Config, m::Breadth, s::Grow, t, i, r::Value) = Execute(m, Grow(s.start, vcat(s.queue, Entry(i, t, Value[s.queue[1].results..., r]))), m.matcher, t, i)

# discard what we have yielded and grown

function failure(k::Config, m::Breadth, s::Grow)
    if (length(s.queue) > 1)
        execute(k, m, BreadthYield(s.start, s.queue[2:end]), arbitrary(s))
    else
        FAILURE
    end
end



# match all in a sequence with backtracking

# there are two nearly identical matchers here - the only difference is 
# whether results are merged (Seq/+) or not (And/&).

# we need two different types so that we can define + and & appropriately.  
# to make the user API more conssistent we also define Series (similar to
# Repeat) that takes a flatten argument.  finally, both are so similar
# that they can share the same state.

abstract Series_<:Matcher

function Series(m::Matcher...; flatten=true)
    if flatten
        Seq(m...)
    else
        And(m...)
    end
end

@auto_hash_equals type Seq<:Series_
    name::Symbol
    matchers::Array{Matcher,1}
    Seq(m::Matcher...) = new(:Seq, [m...])
    Seq(m::Array{Matcher,1}) = new(:Seq, m)
end

serial_success(m::Seq, results::Array{Value,1}) = flatten(results)

@auto_hash_equals type And<:Series_
    name::Symbol
    matchers::Array{Matcher,1}
    And(m::Matcher...) = new(:And, [m...])
    And(m::Array{Matcher,1}) = new(:And,m)
end

# copy to get type right (Array{Value,1} -> Array{Any,1})
serial_success(m::And, results::Array{Value,1}) = Any[results;]

@auto_hash_equals type SeriesState<:State
    results::Array{Value, 1}
    iters::Array{Any,1}
    states::Array{State,1}
end

# when first called, call first matcher

function execute(l::Config, m::Series_, s::Clean, i) 
    if length(m.matchers) == 0
        Success(DIRTY, i, EMPTY)
    else
        Execute(m, SeriesState(Value[], [i], State[]), m.matchers[1], CLEAN, i)
    end
end

# if the final matcher matched then return what we have.  otherwise, evaluate
# the next.

function success(k::Config, m::Series_, s::SeriesState, t, i, r::Value)
    n = length(s.iters)
    results = Value[s.results..., r]
    iters = vcat(s.iters, i)
    states = vcat(s.states, t)
    if n == length(m.matchers)
        Success(SeriesState(results, iters, states), i, serial_success(m, results))
    else
        Execute(m, SeriesState(results, iters, states), m.matchers[n+1], CLEAN, i)
    end
end

# if the first matcher failed, fail.  otherwise backtrack

function failure(k::Config, m::Series_, s::SeriesState)
    n = length(s.iters)
    if n == 1
        FAILURE
    else
        Execute(m, SeriesState(s.results[1:end-1], s.iters[1:end-1], s.states[1:end-1]), m.matchers[n-1], s.states[end], s.iters[end-1])
    end
end

# try to advance the current match

function execute(k::Config, m::Series_, s::SeriesState, i)
    @assert length(s.states) == length(m.matchers)
    Execute(m, SeriesState(s.results[1:end-1], s.iters[1:end-1], s.states[1:end-1]), m.matchers[end], s.states[end], s.iters[end-1])
end




# backtracked alternates

@auto_hash_equals type Alt<:Matcher
    name::Symbol
    matchers::Array{Matcher,1}
    Alt(matchers::Matcher...) = new(:Alt, [matchers...])
    Alt(matchers::Array{Matcher,1}) = new(:Alt, matchers)    
end

@auto_hash_equals type AltState<:State
    state::State
    iter
    i  # index into current alternative
end

function execute(k::Config, m::Alt, s::Clean, i)
    if length(m.matchers) == 0
        FAILURE
    else
        execute(k, m, AltState(CLEAN, i, 1), i)
    end
end

function execute(k::Config, m::Alt, s::AltState, i)
    Execute(m, s, m.matchers[s.i], s.state, s.iter)
end

function success(k::Config, m::Alt, s::AltState, t, i, r::Value)
    Success(AltState(t, s.iter, s.i), i, r)
end

function failure(k::Config, m::Alt, s::AltState)
    if s.i == length(m.matchers)
        FAILURE
    else
        execute(k, m, AltState(CLEAN, s.iter, s.i + 1), s.iter)
    end
end



# evaluate the child, but discard values and do not advance the iter

@auto_hash_equals type Lookahead<:Delegate
    name::Symbol
    matcher::Matcher
    Lookahead(matcher) = new(:Lookahead, matcher)
end

always_print(::Delegate) = true

@auto_hash_equals type LookaheadState<:DelegateState
    state::State
    iter
end

execute(k::Config, m::Lookahead, s::Clean, i) = Execute(m, LookaheadState(s, i), m.matcher, CLEAN, i)

success(k::Config, m::Lookahead, s, t, i, r::Value) = Response(LookaheadState(t, s.iter), s.iter, EMPTY)



# if the child matches, fail; if the child fails return EMPTY
# no backtracking of the child is supported (i don't understand how it would
# work, but feel free to correct me....)

@auto_hash_equals type Not<:Matcher
    name::Symbol
    matcher::Matcher
    Not(matcher) = new(:Not ,matcher)
end

@auto_hash_equals immutable NotState<:State
    iter
end

execute(k::Config, m::Not, s::Clean, i) = Execute(m, NotState(i), m.matcher, CLEAN, i)

success(k::Config, m::Not, s::NotState, t, i, r::Value) = FAILURE

failure(k::Config, m::Not, s::NotState) = SUCCESS(s, s.iter, EMPTY)



# match a regular expression.

# because Regex match against strings, this matcher works only against 
# string sources.

# for efficiency, we need to know the offset where the match finishes.
# we do this by adding r"(.??)" to the end of the expression and using
# the offset from that.

# we also prepend ^ to anchor the match

@auto_hash_equals type Pattern<:Matcher
    name::Symbol
    regex::Regex
    Pattern(r::Regex) = new(:Pattern, Regex("^" * r.pattern * "(.??)"))
    Pattern(s::AbstractString) = new(:Patterm. Regex("^" * s * "(.??)"))
end

print_field(m::Pattern, ::Type{Val{:regex}}) = "r\"$(m.regex.pattern[2:end-5])\""

function execute(k::Config, m::Pattern, s::Clean, i)
    @assert isa(k.source, AbstractString)
    x = match(m.regex, k.source[i:end])
    if x == nothing
        FAILURE
    else
        Success(DIRTY, i + x.offsets[end] - 1, Any[x.match])
    end
end



# support loops

@auto_hash_equals type Delayed<:Matcher
    name::Symbol
    matcher::Nullable{Matcher}
    Delayed() = new(:Delayed, Nullable{Matcher}())
end

function print_matcher(m::Delayed, known::Set{Matcher})
    function producer()
        tag = "$(m.name)"
        if (isnull(m.matcher))
            produce("$(tag) OPEN")
        elseif m in known
            produce("$(tag)...")
        else
            produce("$(tag)")
            push!(known, m)
            for (i, line) in enumerate(print_matcher(get(m.matcher), known))
                produce(i == 1 ? "`-$(line)" : "  $(line)")
            end
        end
    end
    Task(producer)
end

function execute(k::Config, m::Delayed, s::Dirty, i)
    Response(DIRTY, i, FAILURE)
end

function execute(k::Config, m::Delayed, s::State, i)
    if isnull(m.matcher)
        error("set Delayed matcher")
    else
        execute(k, get(m.matcher), s, i)
    end
end



# end of stream / string

@auto_hash_equals immutable Eos<:Matcher 
    name::Symbol
    Eos() = new(:Eos)
end

function execute(k::Config, m::Eos, s::Clean, i)
    if done(k.source, i)
        Success(DIRTY, i, EMPTY)
    else
        FAILURE
    end
end
