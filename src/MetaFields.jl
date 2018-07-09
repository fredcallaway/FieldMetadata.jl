__precompile__()

module MetaFields

using Base: @pure

export @metafield, @chain

"""
Generate a macro that constructs methods of the same name.
These methods return the metafield information provided for each
field of the struct.

```julia
@metafield def_range (0, 0)
@def_range struct Model
    a::Int | (1, 4)
    b::Int | (4, 9)
end

model = Model(3, 5)
def_range(model, Val{:a})
(1, 4)

def_range(model)
((1, 4), (4, 9))
```
"""
macro metafield(name, default)
    symname = QuoteNode(name)
    default = esc(default)
    rename = esc(parse("re$name"))
    name = esc(name)
    return quote
        macro $name(ex)
            name = $symname
            return getparams(ex, name)
        end

        macro $rename(ex)
            name = $symname
            return getparams(ex, name; update = true)
        end

        # Single field methods
        Base.@pure $name(x, key) = $default
        Base.@pure $name(x::Type, key::Type) = $default
        Base.@pure $name(::X, key::Symbol) where X = $name(X, Val{key}) 
        Base.@pure $name(x::X, key::Type) where X = $name(X, key) 
        Base.@pure $name(::Type{X}, key::Symbol) where X = $name(X, Val{key}) 

        # All field methods
        Base.@pure $name(::X) where X = $name(X) 
        Base.@pure $name(::Type{X}) where X = begin
            $name(X, tuple([Val{fn} for fn in fieldnames(X)]...))
        end
        Base.@pure $name(::Type{X}, keys::Tuple) where X = 
            ($name(X, keys[1]), $name(X, Base.tail(keys))...)
        @Base.pure $name(::Type{X}, keys::Tuple{}) where X = tuple()
    end
end

"""
Chain together any macros. Useful for combining @metafield macros.

### Example
```julia
@chain columns @label @units @default_kw

@columns struct Foo
  bar::Int | 7 | u"g" | "grams of bar"
end
```
"""
macro chain(name, ex)
    macros = []
    findhead(x -> push!(macros, x.args[1]), ex, :macrocall)
    return quote
        macro $(esc(name))(ex)
            macros = $macros
            for mac in reverse(macros)
                ex = Expr(:macrocall, mac, ex)
            end
            esc(ex)
        end
    end
end

function getparams(ex, funcname; update = false)
    func_exps = Expr[]
    typ = firsthead(ex, :type) do typ_ex
        return namify(typ_ex.args[2])
    end

    # Parse the block of lines inside the struct.
    # Function expressions are built for each field, and metadata removed.
    firsthead(ex, :block) do block
        for arg in block.args
            if !(:head in fieldnames(arg))
                continue
            elseif arg.head == :(=) # probably using @with_kw
                # TODO make this ignore = in inner constructors
                call = arg.args[2]
                key = getkey(arg.args[1])
                val = call.args[3]
                val == :_ || addmethod!(func_exps, funcname, typ, key, val)
                arg.args[2] = call.args[2]
            elseif arg.head == :call
                arg.args[1] == :(|) || continue
                key = getkey(arg.args[2])
                val = arg.args[3]
                val == :_ || addmethod!(func_exps, funcname, typ, key, val)
                arg.head = arg.args[2].head
                arg.args = arg.args[2].args
            end
        end
    end
    if update
        Expr(:block, func_exps...)
    else
        Expr(:block, :(Base.@__doc__ $(esc(ex))), func_exps...)
    end
end

getkey(ex) = firsthead(y -> y.args[1], ex, :(::))

function addmethod!(func_exps, funcname, typ, key, val)
    # TODO make this less ugly
    func = esc(parse("Base.@pure function $funcname(::Type{<:$typ}, ::Type{Val{:$key}}) :replace end"))
    findhead(func, :block) do l
        l.args[2] = val
    end
    push!(func_exps, func)
end

function findhead(f, ex, sym) 
    found = false
    if :head in fieldnames(ex)
        if ex.head == sym
            f(ex)
            found = true
        end
        found |= any(findhead.(f, ex.args, sym))
    end
    return found
end

function firsthead(f, ex, sym) 
    if :head in fieldnames(ex)
        if ex.head == sym 
            out = f(ex)
            return out
        else
            for arg in ex.args
                x = firsthead(f, arg, sym)
                x == nothing || return x
            end
        end
    end
    return nothing
end

namify(x::Symbol) = x
namify(x::Expr) = namify(x.args[1])

end # module