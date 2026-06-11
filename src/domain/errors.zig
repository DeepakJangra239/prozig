/// Domain error types for the tracker
pub const Error = error{
    /// Invalid lifecycle transition (e.g., Backlog → Done)
    InvalidTransition,
    /// Parent entity not found
    ParentNotFound,
    /// Child cannot advance beyond parent's stage
    ParentChildViolation,
    /// Circular dependency detected
    CircularDependency,
    /// Entity not found
    NotFound,
    /// Already exists (e.g., duplicate agent name)
    AlreadyExists,
    /// Missing required field
    MissingField,
    /// Invalid entity type
    InvalidEntityType,
};
