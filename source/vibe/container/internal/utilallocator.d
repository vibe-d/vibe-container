module vibe.container.internal.utilallocator;

public import stdx.allocator : allocatorObject, CAllocatorImpl, dispose,
	   expandArray, IAllocator, make, makeArray, shrinkArray, theAllocator;
public import stdx.allocator.gc_allocator;
public import stdx.allocator.mallocator;
public import stdx.allocator.building_blocks.affix_allocator;

public import std.typecons;

// NOTE: this needs to be used instead of theAllocator due to Phobos issue 17564
@property IAllocator vibeThreadAllocator()
@safe nothrow @nogc {
	import stdx.allocator.gc_allocator;
	static IAllocator s_threadAllocator;
	if (!s_threadAllocator)
		s_threadAllocator = () @trusted { return allocatorObject(GCAllocator.instance); } ();
	return s_threadAllocator;
}

auto makeGCSafe(T, Allocator, A...)(Allocator allocator, A args)
{
	import core.memory : GC;
	import std.traits : hasIndirections;

	auto ret = allocator.make!T(args);
	static if (is (T == class)) enum tsize = __traits(classInstanceSize, T);
	else enum tsize = T.sizeof;
	static if (hasIndirections!T)
		() @trusted { GC.addRange(cast(void*)ret, tsize, typeid(T)); } ();
	return ret;
}

void disposeGCSafe(T, Allocator)(Allocator allocator, T obj)
{
	import core.memory : GC;
	import std.traits : hasIndirections;

	static if (hasIndirections!T)
		GC.removeRange(cast(void*)obj);
	allocator.dispose(obj);
}

void ensureNotInGC(T)(string info = null) nothrow
{
	import core.exception : InvalidMemoryOperationError;
	try
	{
		import core.memory : GC;
		cast(void) GC.malloc(1);
		return;
	}
	catch(InvalidMemoryOperationError e)
	{
		import core.stdc.stdio : fprintf, stderr;
		import core.stdc.stdlib : exit;
		fprintf(stderr,
				"Error: clean-up of %s incorrectly depends on destructors called by the GC.\n",
				T.stringof.ptr);
		if (info)
			fprintf(stderr, "Info: %s\n", info.ptr);
		assert(false);
	}
}


final class RegionListAllocator(Allocator, bool leak = false) : IAllocator {
	import std.algorithm.comparison : min, max;
	import std.conv : emplace;

	import std.typecons : Ternary;

	static struct Pool { Pool* next; void[] data; void[] remaining; }
	private {
		Allocator m_baseAllocator;
		Pool* m_freePools;
		Pool* m_fullPools;
		size_t m_poolSize;
	}

	this(size_t pool_size, Allocator base) @safe nothrow
	{
		m_poolSize = pool_size;
		m_baseAllocator = base;
	}

	~this()
	{
		deallocateAll();
	}

	override @property uint alignment() const { return 0x10; }

	@property size_t totalSize()
	@safe nothrow @nogc {
		size_t amt = 0;
		for (auto p = m_fullPools; p; p = p.next)
			amt += p.data.length;
		for (auto p = m_freePools; p; p = p.next)
			amt += p.data.length;
		return amt;
	}

	@property size_t allocatedSize()
	@safe nothrow @nogc {
		size_t amt = 0;
		for (auto p = m_fullPools; p; p = p.next)
			amt += p.data.length;
		for (auto p = m_freePools; p; p = p.next)
			amt += p.data.length - p.remaining.length;
		return amt;
	}

	override void[] allocate(size_t sz, TypeInfo ti = null)
	{
		auto aligned_sz = alignedSize(sz);

		Pool* pprev = null;
		Pool* p = cast(Pool*)m_freePools;
		while( p && p.remaining.length < aligned_sz ){
			pprev = p;
			p = p.next;
		}

		if( !p ){
			auto pmem = m_baseAllocator.allocate(AllocSize!Pool);

			p = emplace!Pool(cast(Pool*)pmem.ptr);
			p.data = m_baseAllocator.allocate(max(aligned_sz, m_poolSize));
			p.remaining = p.data;
			p.next = cast(Pool*)m_freePools;
			m_freePools = p;
			pprev = null;
		}

		auto ret = p.remaining[0 .. aligned_sz];
		p.remaining = p.remaining[aligned_sz .. $];
		if( !p.remaining.length ){
			if( pprev ){
				pprev.next = p.next;
			} else {
				m_freePools = p.next;
			}
			p.next = cast(Pool*)m_fullPools;
			m_fullPools = p;
		}

		return ret[0 .. sz];
	}

	override void[] alignedAllocate(size_t n, uint a) { return null; }
	override bool alignedReallocate(ref void[] b, size_t size, uint alignment) { return false; }
	override void[] allocateAll() { return null; }
	override @property Ternary empty() const { return m_fullPools !is null ? Ternary.no : Ternary.yes; }
	override size_t goodAllocSize(size_t s) { return alignedSize(s); }

	import std.traits : Parameters;
	static if (is(Parameters!(IAllocator.resolveInternalPointer)[0] == const(void*))) {
		override Ternary resolveInternalPointer(const void* p, ref void[] result) { return Ternary.unknown; }
	} else {
		override Ternary resolveInternalPointer(void* p, ref void[] result) { return Ternary.unknown; }
	}
	static if (is(Parameters!(IAllocator.owns)[0] == const(void[]))) {
		override Ternary owns(const void[] b) { return Ternary.unknown; }
	} else {
		override Ternary owns(void[] b) { return Ternary.unknown; }
	}


	override bool reallocate(ref void[] arr, size_t newsize)
	{
		return expand(arr, newsize);
	}

	override bool expand(ref void[] arr, size_t newsize)
	{
		auto aligned_sz = alignedSize(arr.length);
		auto aligned_newsz = alignedSize(newsize);

		if (aligned_newsz <= aligned_sz) {
			arr = arr[0 .. newsize]; // TODO: back up remaining
			return true;
		}

		auto pool = m_freePools;
		bool last_in_pool = pool && arr.ptr+aligned_sz == pool.remaining.ptr;
		if (last_in_pool && pool.remaining.length+aligned_sz >= aligned_newsz) {
			pool.remaining = pool.remaining[aligned_newsz-aligned_sz .. $];
			arr = arr.ptr[0 .. aligned_newsz];
			assert(arr.ptr+arr.length == pool.remaining.ptr, "Last block does not align with the remaining space!?");
			arr = arr[0 .. newsize];
		} else {
			auto ret = allocate(newsize);
			assert(ret.ptr >= arr.ptr+aligned_sz || ret.ptr+ret.length <= arr.ptr, "New block overlaps old one!?");
			ret[0 .. min(arr.length, newsize)] = arr[0 .. min(arr.length, newsize)];
			arr = ret;
		}
		return true;
	}

	override bool deallocate(void[] mem)
	{
		return false;
	}

	override bool deallocateAll() {
		return deallocateAll(Yes.freeMemory);
	}

	bool deallocateAll(Flag!"freeMemory" freeMemory = Yes.freeMemory)
	{
		// put all full Pools into the free pools list
		for (Pool* p = cast(Pool*)m_fullPools, pnext; p; p = pnext) {
			pnext = p.next;
			p.next = cast(Pool*)m_freePools;
			m_freePools = cast(Pool*)p;
		}

		// free up all pools
		for (Pool* p = cast(Pool*)m_freePools; p; p = p.next)
			p.remaining = p.data;

		if (freeMemory == Yes.freeMemory) {
			Pool* pnext;
			for (auto p = cast(Pool*)m_freePools; p; p = pnext) {
				pnext = p.next;
				static if (!leak) {
					m_baseAllocator.deallocate(p.data);
					m_baseAllocator.deallocate((cast(void*)p)[0 .. AllocSize!Pool]);
				}
			}
			m_freePools = null;
		}

		return true;
	}
}

unittest {
	auto alloc = new RegionListAllocator!(shared(GCAllocator))(1024, GCAllocator.instance);
	auto mem = alloc.allocate(8);
	assert(mem.length == 8);
	alloc.deallocateAll();
}

template AllocSize(T)
{
	static if (is(T == class)) {
		// workaround for a strange bug where AllocSize!SSLStream == 0: TODO: dustmite!
		enum dummy = T.stringof ~ __traits(classInstanceSize, T).stringof;
		enum AllocSize = __traits(classInstanceSize, T);
	} else {
		enum AllocSize = T.sizeof;
	}
}

enum size_t alignment = 0x10;
enum size_t alignmentMask = alignment-1;

size_t alignedSize(size_t sz) nothrow
{
	return ((sz + alignment - 1) / alignment) * alignment;
}

unittest {
	foreach( i; 0 .. 20 ){
		auto ia = alignedSize(i);
		assert(ia >= i);
		assert((ia & alignmentMask) == 0);
		assert(ia < i+alignment);
	}
}
