function mustBeMdoAfgImpedanceEnum(func)
    if(~isa(func, 'MdoAfgImpedanceEnum'))
        me = MException('mustBeMdoAfgImpedanceEnum', ...
            "the input must be a type of MdoAfgImpedanceEnum");
        throw(me);
    end
end