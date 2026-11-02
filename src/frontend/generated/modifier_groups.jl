# Spec.ModifierGroups
#
# Generated from the OpenMP 6.1 specification, revision d694c8d27: do not edit.

"""
    Spec.ModifierGroups

Modifier groups, one constant per group.
"""
baremodule ModifierGroups

using ..Schema

const adjust_op = ModifierGroupSpec(
    name = :adjust_op,
    modifiers = (:nothing, :need_device_addr, :need_device_ptr),
    clauses = (:adjust_args,),
    properties = (:required, :exclusive),
)

const depend_list_type = ModifierGroupSpec(
    name = :depend_list_type,
    modifiers = (:depobj_modifier, :loc_modifier),
    clauses = (:depend,),
    properties = (:exclusive,),
)

const interop_type = ModifierGroupSpec(
    name = :interop_type,
    modifiers = (:target_type, :targetsync_type),
    clauses = (:init,),
)

const map_type_modifying = ModifierGroupSpec(
    name = :map_type_modifying,
    modifiers = (
        :present_modifier,
        :always_modifier,
        :delete_modifier,
        :close_modifier,
        :self_modifier,
    ),
    clauses = (:map,),
)

const reduction_type = ModifierGroupSpec(
    name = :reduction_type,
    modifiers = (
        :inscan_modifier,
        :noncommutative_modifier,
        :task_modifier,
        :default_modifier,
    ),
    clauses = (:reduction,),
    properties = (:exclusive,),
)

const variable_selector = ModifierGroupSpec(
    name = :variable_selector,
    modifiers = (:variable_category, :optional_modifier),
    clauses = (:default, :defaultmap),
    properties = (:required,),
)

end # baremodule ModifierGroups
