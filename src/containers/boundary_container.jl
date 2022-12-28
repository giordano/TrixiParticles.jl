"""
    BoundaryParticleContainer(coordinates, mass, model;
                              movement_function=nothing)

Container for boundaries modeled by boundary particles.
The container is initialized with the coordinates of the particles and their masses.
The interaction between fluid and boundary particles is specified by the boundary model.

The `movement_function` is to define in which way the boundary particles move over time. Its
boolean return value is mandatory to determine in each timestep if the particles are moving or not.
This determines if the neighborhood search will be updated.
In the example below the `movement_function` only returns `true` (container is moving)
if the simulation time is lower than `0.1`.


# Examples
```julia
function movement_function(coordinates, t)

    if t < 0.1
        f(t) = 0.5*t^2 + t
        pos_1 = coordinates[2,1]
        pos_2 = f(t)
        diff_pos = pos_2 - pos_1
        coordinates[2,:] .+= diff_pos

        return true
    end

    return false
end
```
"""
struct BoundaryParticleContainer{NDIMS, ELTYPE<:Real, BM, MF} <: ParticleContainer{NDIMS}
    initial_coordinates ::Array{ELTYPE, 2}
    mass                ::Vector{ELTYPE}
    boundary_model      ::BM
    movement_function   ::MF
    ismoving            ::Vector{Bool}

    function BoundaryParticleContainer(coordinates, mass, model;
                                       movement_function=nothing)
        NDIMS = size(coordinates, 1)
        ismoving = zeros(Bool, 1)

        return new{NDIMS, eltype(coordinates), typeof(model), typeof(movement_function)}(
            coordinates, mass, model, movement_function, ismoving)
    end
end


# No particle positions are advanced for boundary containers
@inline n_moving_particles(container::BoundaryParticleContainer) = 0


@inline function get_current_coords(particle, u, container::BoundaryParticleContainer)
    @unpack initial_coordinates = container

    return get_particle_coords(particle, initial_coordinates, container)
end


function initialize!(container::BoundaryParticleContainer, neighborhood_search)
    # Nothing to initialize for this container
    return container
end

function update!(container::BoundaryParticleContainer, u, u_ode, neighborhood_search, semi, t)
    @unpack movement_function, initial_coordinates = container

    container.ismoving[1] = move_boundary_particles!(movement_function, initial_coordinates, t)

    return container
end

move_boundary_particles!(movement_function, coordinates, t) = movement_function(coordinates, t)

move_boundary_particles!(movement_function::Nothing, coordinates, t) = false

function write_variables!(u0, container::BoundaryParticleContainer)
    return u0
end


function interact!(du, u_particle_container, u_neighbor_container, neighborhood_search,
                   particle_container::BoundaryParticleContainer,
                   neighbor_container)
    # No interaction towards the boundary particles
    return du
end


@inline function boundary_particle_impact(particle, particle_container, boundary_container,
                                          pos_diff, distance, density_a, m_b)
    @unpack boundary_model = boundary_container

    boundary_particle_impact(particle, particle_container, pos_diff, distance, density_a, m_b,
                             boundary_model)
end


# TODO
@doc raw"""
    BoundaryModelMonaghanKajtar(K, beta, boundary_particle_spacing)

Boundaries modeled as boundary particles which exert forces on the fluid particles (Monaghan, Kajtar, 2009).
The force on fluid particle ``a`` is given by
```math
f_a = m_a \left(\sum_{b \in B} f_{ab} - m_b \Pi_{ab} \nabla_{r_a} W(\Vert r_a - r_b \Vert, h)\right)
```
with
```math
f_{ab} = \frac{K}{\beta} \frac{r_{ab}}{\Vert r_{ab} \Vert (\Vert r_{ab} \Vert - d)} \Phi(\Vert r_{ab} \Vert, h)
\frac{2 m_b}{m_a + m_b},
```
where ``B`` denotes the set of boundary particles, ``m_a`` and ``m_b`` are the masses of
fluid particle ``a`` and boundary particle ``b`` respectively,
``r_{ab} = r_a - r_b`` is the difference of the coordinates of particles ``a`` and ``b``,
and ``d`` denotes the boundary particle spacing
(see (Monaghan, Kajtar, 2009, Equation (3.1)) and (Valizadeh, Monaghan, 2015)).
Here, ``\Phi`` denotes the 1D Wendland C4 kernel, normalized to ``1.77`` for ``q=0``
(Monaghan, Kajtar, 2009, Section 4), with ``\Phi(r, h) = w(r/h)`` and
```math
w(q) =
\begin{cases}
  (1.77/32) (1 + (5/2)q + 2q^2)(2 - q)^5  & \text{if } 0 \leq q < 2 \\
  0                                       & \text{if } q \geq 2.
\end{cases}
```

The boundary particles are assumed to have uniform spacing by the factor ``\beta`` smaller
than the expected fluid particle spacing.
For example, if the fluid particles have an expected spacing of ``0.3`` and the boundary particles
have a uniform spacing of ``0.1``, then this parameter should be set to ``\beta = 3``.
According to (Monaghan, Kajtar, 2009), a value of ``\beta = 3`` for the Wendland C4 that
we use here is reasonable for most computing purposes.

The parameter ``K`` is used to scale the force exerted by the boundary particles.
In (Monaghan, Kajtar, 2009), a value of ``gD`` is used for static tank simulations,
where ``g`` is the gravitational acceleration and ``D`` is the depth of the fluid.

The viscosity ``\Pi_{ab}`` is calculated according to the viscosity used in the
simulation, where the density of the boundary particle if needed is assumed to be
identical to the density of the fluid particle.

References:
- Joseph J. Monaghan, Jules B. Kajtar. "SPH particle boundary forces for arbitrary boundaries".
  In: Computer Physics Communications 180.10 (2009), pages 1811–1820.
  [doi: 10.1016/j.cpc.2009.05.008](https://doi.org/10.1016/j.cpc.2009.05.008)
- Alireza Valizadeh, Joseph J. Monaghan. "A study of solid wall models for weakly compressible SPH."
  In: Journal of Computational Physics 300 (2015), pages 5–19.
  [doi: 10.1016/J.JCP.2015.07.033](https://doi.org/10.1016/J.JCP.2015.07.033)
"""
struct BoundaryModelMonaghanKajtar{ELTYPE<:Real}
    K                           ::ELTYPE
    beta                        ::ELTYPE
    boundary_particle_spacing   ::ELTYPE

    function BoundaryModelMonaghanKajtar(K, beta, boundary_particle_spacing)
        new{typeof(K)}(K, beta, boundary_particle_spacing)
    end
end


@inline function boundary_kernel(r, h)
    q = r / h

    # TODO The neighborhood search fluid->boundary should use this search distance
    if q >= 2
        return 0.0
    end

    # (Monaghan, Kajtar, 2009, Section 4): The kernel should be normalized to 1.77 for q=0
    return 1.77/32 * (1 + 5/2 * q + 2 * q^2) * (2 - q)^5
end


@inline function boundary_particle_impact(particle, particle_container,
                                          pos_diff, distance, density_a, m_b,
                                          boundary_model::BoundaryModelMonaghanKajtar)
    @unpack smoothing_length = particle_container
    @unpack K, beta, boundary_particle_spacing = boundary_model

    NDIMS = ndims(particle_container)
    return K / beta^(NDIMS-1) * pos_diff / (distance * (distance - boundary_particle_spacing)) *
        boundary_kernel(distance, smoothing_length)
end


"""
TODO
"""
struct BoundaryModelFrozen{ELTYPE<:Real}
    rest_density::ELTYPE

    function BoundaryModelFrozen(rest_density)
        new{typeof(rest_density)}(rest_density)
    end
end


@inline function boundary_particle_impact(particle, particle_container,
                                          pos_diff, distance, density_a, m_b,
                                          boundary_model::BoundaryModelFrozen)
    @unpack pressure, smoothing_kernel, smoothing_length = particle_container
    @unpack rest_density = boundary_model

    grad_kernel = kernel_deriv(smoothing_kernel, distance, smoothing_length) * pos_diff / distance

    # Use 0 as boundary particle pressure
    return -m_b * (pressure[particle] / density_a^2 + 0 / rest_density^2) * grad_kernel
end