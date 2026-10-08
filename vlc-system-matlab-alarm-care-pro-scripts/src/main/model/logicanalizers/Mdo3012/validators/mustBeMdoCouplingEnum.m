function mustBeMdoCouplingEnum(state)
    if(~isa(state, 'MdoCouplingEnum'))
        me = MException('mustBeMdoCouplingEnum', ...
            "the input must be a type of MdoCouplingEnum");
        throw(me);
    end
end