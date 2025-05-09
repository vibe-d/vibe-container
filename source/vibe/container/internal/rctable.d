module vibe.container.internal.rctable;

import vibe.container.internal.utilallocator;

import std.traits;


struct RCTable(T, Allocator = IAllocator) {
	import core.memory : GC;

	// NOTE: AffixAllocator doesn't handle alignment correctly for the actual
	//       payload, so we need to explicitly make the prefix alignment
	//       consistent
	align(GCAllocator.alignment) struct RC { int rc; }

	enum needManualAlignment = T.alignof > GCAllocator.alignment;

	Allocator AW(Allocator a) { return a; }
	alias AllocatorType = AffixAllocator!(Allocator, RC);
	static if (is(typeof(AllocatorType.instance)))
		alias AllocatorInstanceType = typeof(AllocatorType.instance);
	else alias AllocatorInstanceType = AllocatorType;

	private {
		static if (needManualAlignment) {
			ubyte[] m_unalignedTable;
		}
		T[] m_table; // NOTE: capacity is always POT
		static if (!is(typeof(Allocator.instance)))
			AllocatorInstanceType m_allocator;
	}

	static if (!is(typeof(Allocator.instance))) {
		this(Allocator allocator)
		{
			m_allocator = typeof(m_allocator)(AW(allocator));
		}
	}

	this(this)
	@trusted {
		if (m_table.ptr)
			this.refCount++;
	}

	~this()
	@trusted {
		if (m_table.ptr && --this.refCount == 0) {
			static if (hasIndirections!T && !is(Allocator == GCAllocator)) {
				if (m_table.ptr !is null) () @trusted {
					GC.removeRange(m_table.ptr);
				}();
			}

			try {
				static if (needManualAlignment) {
					static if (hasElaborateDestructor!T)
						foreach (ref el; m_table)
							destroy(el);
					allocator.deallocate(m_unalignedTable);
				} else {
					allocator.dispose(m_table);
				}
			} catch (Exception e) assert(false, e.msg);
		}
	}

	// Initializes the table with the given size
	void initialize(size_t length)
	{
		assert(!m_table.ptr);

		try {
			static if (needManualAlignment) {
				m_unalignedTable = cast(ubyte[])allocator.allocate((length + 1) * T.sizeof);
				() @trusted {
					import core.lifetime : emplace;
					auto mem = cast(ubyte[])m_unalignedTable;
					mem = mem[T.alignof - cast(size_t)mem.ptr % T.alignof .. $];
					assert(cast(size_t)mem.ptr % T.alignof == 0);
					m_table = cast(T[])mem[0 .. length * T.sizeof];
					foreach (ref el; m_table)
						emplace!T(&el);
				} ();
			} else {
				m_table = allocator.makeArray!T(length);
			}
			assert(cast(size_t)cast(void*)m_table.ptr % T.alignof == 0);
			this.refCount = 1;
		} catch (Exception e) assert(false, e.msg);

		static if (hasIndirections!T && !is(Allocator == GCAllocator))
			GC.addRange(m_table.ptr, m_table.length * T.sizeof, typeid(T[]));
	}

	/// Deallocates without running destructors
	void deallocate()
	nothrow {
		try {
			static if (hasIndirections!T && !is(Allocator == GCAllocator))
				if (m_table.ptr !is null)
					GC.removeRange(m_table.ptr);

			static if (needManualAlignment) {
				allocator.deallocate(m_unalignedTable);
				m_unalignedTable = null;
			} else{
				allocator.deallocate(m_table);
			}
			m_table = null;
		} catch (Exception e) assert(false, e.msg);
	}

	// Creates a new table with the given length, using the same allocator
	RCTable createNew(size_t length)
	nothrow {
		static if (!is(typeof(Allocator.instance)))
			auto ret = RCTable(m_allocator._parent);
		else RCTable ret;
		ret.initialize(length);
		return ret;
	}

	/// Determines whether this reference to the table is unique
	bool isUnique()
	{
		return m_table.ptr is null || this.refCount == 1;
	}

	// duplicates all elements  to a newly allocated table
	RCTable dup()
	{
		auto ret = createNew(m_table.length);
		ret.m_table[] = m_table;
		return ret;
	}

	inout(T)[] get() inout return { return m_table; }

	alias get this;

	private ref int refCount()
	return nothrow {
		static if (needManualAlignment)
			return allocator.prefix(m_unalignedTable).rc;
		else return allocator.prefix(m_table).rc;
	}

	private @property AllocatorInstanceType allocator()
	{
		static if (is(typeof(Allocator.instance)))
			return AllocatorType.instance;
		else {
			if (!m_allocator._parent) {
				static if (is(Allocator == IAllocator)) {
					try m_allocator = typeof(m_allocator)(AW(vibeThreadAllocator()));
					catch (Exception e) assert(false, e.msg);
				} else assert(false, "Allocator not initialized.");
			}
			return m_allocator;
		}
	}
}

unittest { // check that aligned initialization works correctly
	align(64)
	struct S {
		ubyte[16] a = 0x00;
		ubyte[16] b = 0xFF;
	}

	RCTable!S table;
	foreach (i; 0 .. 100) {
		table = table.createNew(4);
		assert(table[0] == S.init);
	}
}
