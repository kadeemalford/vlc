function mustBeMdoStateEnum(state)
    if(~isa(state, 'MdoStateEnum'))
        me = MException('mustBeMdoStateEnum', ...
            "the input must be a type of MdoStateEnum");
        throw(me);
    end
end