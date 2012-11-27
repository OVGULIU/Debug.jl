
#   Debug.Graft:
# ================
# Debug instrumentation of code, and transformation of ASTs to act as if they
# were evaluated inside such code (grafting)

module Graft
using Base, AST
import Base.ref, Base.assign, Base.has

export Scope, NoScope, LocalScope


# ---- Helpers ----------------------------------------------------------------

quot(ex) = expr(:quote, {ex})

is_expr(ex,       head)           = false
is_expr(ex::Expr, head::Symbol)   = ex.head == head
is_expr(ex::Expr, heads::Set)     = has(heads, ex.head)
is_expr(ex::Expr, heads::Vector)  = contains(heads, ex.head)
is_expr(ex, head::Symbol, n::Int) = is_expr(ex, head) && length(ex.args) == n

const typed_dict                = symbol("typed-dict")


# ---- Scope: runtime symbol table with getters and setters -------------------

abstract Scope

type NoScope <: Scope; end
type LocalScope <: Scope
    parent::Scope
    syms::Dict
end

has(s::NoScope,    sym::Symbol) = false
has(s::LocalScope, sym::Symbol) = has(s.syms, sym) || has(s.parent, sym)

function get_entry(scope::LocalScope, sym::Symbol)
    has(scope.syms, sym) ? scope.syms[sym] : get_entry(scope.parent, sym)
end

getter(scope::LocalScope, sym::Symbol) = get_entry( scope, sym)[1]
setter(scope::LocalScope, sym::Symbol) = get_entry( scope, sym)[2]
ref(   scope::LocalScope,     sym::Symbol) = getter(scope, sym)()
assign(scope::LocalScope, x,  sym::Symbol) = setter(scope, sym)(x)

function code_getset(sym::Symbol)
    val = gensym(string(sym))
    :( ()->$sym, $val->($sym=$val) )
end
function code_scope(scopesym::Symbol, parent, syms)
    pairs = {expr(:(=>), quot(sym), code_getset(sym)) for sym in syms}
    :(local $scopesym = $(quot(LocalScope))($parent, $(expr(typed_dict, 
        :($(quot(Symbol))=>$(quot((Function,Function)))), pairs...))))
end


# ---- instrument -------------------------------------------------------------
# Add Scope creation and debug traps to (analyzed) code
# A call to trap() is added after every AST.Line (expr(:line) / LineNumberNode)

type Context
    trap_ex
    env::Env
    scope_ex
end

function instrument(trap_ex, ex)
    instrument(Context(trap_ex, NoEnv(), quot(NoScope())), ex)
end

instrument(c::Context, node::Union(Leaf,Sym,Line)) = node.ex
function instrument(c::Context, ex::Expr)
    expr(ex.head, {instrument(c, arg) for arg in ex.args})
end
function instrument(c::Context, ex::Block)
    code = {}
    if !is(ex.env, c.env)
        syms, e = Set{Symbol}(), ex.env
        while !is(e, c.env);  add_each(syms, e.defined); e = e.parent;  end

        name = gensym("scope")
        push(code, code_scope(name, c.scope_ex, syms))
        c = Context(c.trap_ex, ex.env, name)
    end
    
    for arg in ex.args
        push(code, instrument(c, arg))
        if isa(arg, Line)
            push(code, :($(c.trap_ex)($(arg.line), $(quot(arg.file)),
                                      $(c.scope_ex))) )
        end
    end
    expr(:block, code)
end


# ---- graft ------------------------------------------------------------------
# Rewrite an (analyzed) AST to work as if it were inside
# the given scope, when evaluated in global scope. 
# Replaces reads and writes to variables from that scope 
# with getter/setter calls.

const updating_ops = {
 :+= => :+,   :-= => :-,  :*= => :*,  :/= => :/,  ://= => ://, :.//= => :.//,
:.*= => :.*, :./= => :./, :\= => :\, :.\= => :.\,  :^= => :^,   :.^= => :.^,
 :%= => :%,   :|= => :|,  :&= => :&,  :$= => :$,  :<<= => :<<,  :>>= => :>>,
 :>>>= => :>>>}

graft(s::LocalScope, ex)                     = ex
graft(s::LocalScope, node::Union(Leaf,Line)) = node.ex
function graft(s::LocalScope, ex::Sym)
    sym = ex.ex
    (has(s, sym) && !has(ex.env, sym)) ? expr(:call, quot(getter(s,sym))) : sym
end
function graft(s::LocalScope, ex::Union(Expr, Block))
    head, args = get_head(ex), ex.args
    if head == :(=)
        lhs, rhs = args
        if isa(lhs, Sym)             # assignment to symbol
            rhs = graft(s, rhs)
            sym = lhs.ex
            if has(lhs.env, sym); return :($sym = $rhs)
            elseif has(s, sym);   return expr(:call, quot(setter(s,sym)), rhs)
            else; error("No setter in scope found for $(sym)!")
            end
        elseif is_expr(lhs, :tuple)  # assignment to tuple
            tup = Leaf(gensym("tuple")) # don't recurse into tup
            return graft(s, expr(:block,
                 :( $tup  = $rhs     ),
                {:( $dest = $tup[$k] ) for (k,dest)=enumerate(lhs.args)}...))
        elseif is_expr(lhs, [:ref, :.]) || isa(lhs, Leaf) # need no lhs rewrite
        else error("graft: not implemented: $ex")       
        end  
    elseif has(updating_ops, head) && isa(args[1], Sym)  # x+=y ==> x=x+y etc.
        op = updating_ops[head]
        return graft(s, :( $(args[1]) = ($op)($(args[1]), $(args[2])) ))
    end        
    expr(head, {graft(s,arg) for arg in args})
end

end # module