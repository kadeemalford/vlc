function mustBeMdoAfgFunctionEnum(func)
    if(~isa(func, 'MdoAfgFunctionEnum'))
        me = MException('mustBeMdoAfgFunctionEnum', ...
            "the input must be a type of MdoAfgFunctionEnum");
        throw(me);
    end
end