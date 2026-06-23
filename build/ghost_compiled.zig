const std = @import("std");
const vsa = @import("vsa_core.zig");
const codebook = @import("concept_codebook.zig");

/// Thermodynamic equilibrium threshold.
const EQUILIBRIUM_EPSILON: u64 = 0;

/// Safety valve: absolute maximum iterations to prevent infinite loops.
const MAX_SAFETY_ITERATIONS: usize = 10000;

/// Phase 3.3: Topological link with positional branching.
/// Each child knows its parent AND which positional slot it occupies.
pub const TopologyLink = struct {
    parent: usize,
    position: u8, // Which Port_Child_i this child is bound to
};

/// The Constrained Solver for AST generation.
/// Phase 3.3: Z-Axis topology with positional branching.
pub const FlameSolver = struct {
    allocator: std.mem.Allocator,
    nodes: []vsa.HyperVector,
    raw_nodes: []vsa.HyperVector,
    pinned_slots: []bool,
    
    // Z-Axis topological constraints with positional branching
    topology: []?TopologyLink,
    
    /// Thermodynamic state
    last_total_energy: u64 = 0,
    convergence_iterations: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, size: usize) !FlameSolver {
        const nodes = try allocator.alloc(vsa.HyperVector, size);
        const raw_nodes = try allocator.alloc(vsa.HyperVector, size);
        for (0..size) |i| {
            const seed = vsa.generate(@intCast(0x13370000 + i));
            nodes[i] = seed;
            raw_nodes[i] = seed;
        }
        
        const pinned_slots = try allocator.alloc(bool, size);
        @memset(pinned_slots, false);
        
        const topology = try allocator.alloc(?TopologyLink, size);
        @memset(topology, null);
        
        return FlameSolver{
            .allocator = allocator,
            .nodes = nodes,
            .raw_nodes = raw_nodes,
            .pinned_slots = pinned_slots,
            .topology = topology,
            .last_total_energy = 0,
            .convergence_iterations = 0,
        };
    }
    
    pub fn getIndexOfRaw(self: *FlameSolver, vector: vsa.HyperVector) usize {
        for (self.raw_nodes, 0..) |n, i| {
            if (vsa.hammingDistance(n, vector) == 0) return i;
        }
        return 0;
    }

    pub fn deinit(self: *FlameSolver) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.raw_nodes);
        self.allocator.free(self.pinned_slots);
        self.allocator.free(self.topology);
    }
    
    /// Pins a vector in place, enabling the Inertia Mask for this slot.
    pub fn pin(self: *FlameSolver, index: usize, vector: vsa.HyperVector) void {
        if (index < self.nodes.len) {
            self.nodes[index] = vector;
            self.raw_nodes[index] = vector;
            self.pinned_slots[index] = true;
        }
    }
    
    /// Phase 3.3: Establishes Z-Axis hierarchical constraint WITH positional branching.
    /// child_index is bound to parent_index at the given child position (0, 1, 2...).
    pub fn pinTopology(self: *FlameSolver, child_index: usize, parent_index: usize, position: u8) void {
        if (child_index < self.nodes.len and parent_index < self.nodes.len) {
            self.topology[child_index] = .{ .parent = parent_index, .position = position };
        }
    }
    
    /// Calculate thermodynamic energy using positional child ports.
    fn calculateTotalEnergy(self: *FlameSolver) u64 {
        var total_energy: u64 = 0;
        for (0..self.nodes.len) |i| {
            if (self.topology[i]) |link| {
                const port = codebook.getChildPort(link.position);
                
                // Constraint 1: child bound with its positional port should be close to parent
                const child_bound = vsa.bind(self.raw_nodes[i], port);
                total_energy += @as(u64, vsa.math.hammingDistance(self.raw_nodes[link.parent], child_bound));
                
                // Constraint 2: parent unbound with the positional port should be close to child
                const parent_unbound = vsa.bind(self.raw_nodes[link.parent], port);
                total_energy += @as(u64, vsa.math.hammingDistance(self.raw_nodes[i], parent_unbound));
            }
        }
        return total_energy;
    }
    
    pub fn relax(self: *FlameSolver, _ignored_iterations: usize) void {
        _ = _ignored_iterations;
        self.relaxToEquilibrium();
    }
    
    /// The true thermodynamic relaxation. Runs until dE = 0.
    pub fn relaxToEquilibrium(self: *FlameSolver) void {
        var next_state = self.allocator.alloc(vsa.HyperVector, self.nodes.len) catch return;
        defer self.allocator.free(next_state);
        
        @memcpy(next_state, self.raw_nodes);
        
        var prev_energy = self.calculateTotalEnergy();
        var iter: usize = 0;
        
        while (iter < MAX_SAFETY_ITERATIONS) : (iter += 1) {
            for (0..self.nodes.len) |i| {
                // Z-Axis Depth Topology with Positional Branching
                var influences = std.ArrayList(vsa.HyperVector).init(self.allocator);
                defer influences.deinit();
                
                // Add inertia (self)
                influences.append(self.raw_nodes[i]) catch {};
                
                // If I have a parent, I am influenced by my parent's expectation
                // of a child at MY specific positional slot
                if (self.topology[i]) |link| {
                    const port = codebook.getChildPort(link.position);
                    const parent_influence = vsa.bind(self.raw_nodes[link.parent], port);
                    influences.append(parent_influence) catch {};
                }
                
                // If I am a parent to children, each child at its positional
                // slot exerts geometric tension through its specific port
                for (0..self.nodes.len) |c_idx| {
                    if (self.topology[c_idx]) |child_link| {
                        if (child_link.parent == i) {
                            const port = codebook.getChildPort(child_link.position);
                            const child_influence = vsa.bind(self.raw_nodes[c_idx], port);
                            influences.append(child_influence) catch {};
                        }
                    }
                }
                
                // If no topological constraints, fallback to noise
                if (influences.items.len == 1) {
                    influences.append(vsa.math.generate(@intCast(0x0B000000 + i))) catch {};
                }
                
                const bundled = vsa.math.bundleN(influences.items);
                next_state[i] = bundled;
            }
            
            @memcpy(self.raw_nodes, next_state);
            
            // Thermodynamic halt: calculate dE
            const current_energy = self.calculateTotalEnergy();
            const delta_energy = if (prev_energy > current_energy) 
                prev_energy - current_energy 
            else 
                current_energy - prev_energy;
            
            if (delta_energy <= EQUILIBRIUM_EPSILON) {
                break;
            }
            
            prev_energy = current_energy;
        }
        
        self.convergence_iterations = iter;
        self.last_total_energy = prev_energy;
        
        // AUTO-ASSOCIATIVE CLEANUP MEMORY (Vector Quantization)
        for (0..self.nodes.len) |i| {
            if (!self.pinned_slots[i]) {
                self.nodes[i] = codebook.quantize(self.raw_nodes[i]);
            }
        }
    }
};
