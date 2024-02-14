/**
	Ring buffer supporting fixed or dynamic capacity

	Copyright: © 2013-2024 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.container.ringbuffer;


/** Ring buffer implementation.

	This implementation supports dynamic capacity, where the memory is allocated
	dynamically using the garbage collector (`N == 0`), as well as fixed
	capacity where the array contents are part of the struct itself (e.g. stack
	allocated, `N > 0`).

	`RingBuffer` implements an output range interface, extended with additional
	`putN` and `peekDst` methods.

	Reading follows the conventions of the D standard library, providing `empty`,
	`length`, `front` and `back` properties, as well as slice and index based
	random access.

	Both, FIFO and LIFO operation modes are supported, using `removeFront` and
	`removeBack`.

	This struct has value semantics - copying the a `RingBuffer` value will copy
	the whole buffer. Copy-on-write optimization may be implemented in the future,
	but generally copying is discouraged.
*/
struct RingBuffer(T, size_t N = 0, bool INITIALIZE = true) {
	import std.traits : hasElaborateDestructor, isCopyable;
	import std.algorithm.comparison : min;
	import std.algorithm.mutation : move;

	private {
		static if( N > 0 ) {
			static if (INITIALIZE) T[N] m_buffer;
			else T[N] m_buffer = void;
		} else T[] m_buffer;
		size_t m_start = 0;
		size_t m_fill = 0;
	}

	static if (N == 0) {
		/// Constructs a new rung buffer with given capacity (only if `N == 0`).
		this(size_t capacity) { m_buffer = new T[capacity]; }

		this(this)
		{
			if (m_buffer.length)
				m_buffer = m_buffer.dup;
		}

		~this()
		{
			if (m_buffer.length > 0) {
				static if (hasElaborateDestructor!T) {
					foreach (i; 0 .. m_fill)
						destroy(m_buffer[mod(m_start + i)]);
				}
			}
		}
	}

	/// Tests whether there are any elements in the buffer.
	@property bool empty() const { return m_fill == 0; }

	/// Tests whether there is any space left in the buffer.
	@property bool full() const { return m_fill == m_buffer.length; }

	/// Number of elements contained in the buffer
	@property size_t length() const { return m_fill; }

	/// Number of elements that can still be put into the buffer
	@property size_t freeSpace() const { return m_buffer.length - m_fill; }

	/// Overall number of elements that fit into the buffer
	@property size_t capacity() const { return m_buffer.length; }
	static if (N == 0) {
		/// ditto
		@property void capacity(size_t new_size)
		{
			if (m_buffer.length) {
				auto newbuffer = new T[new_size];
				auto dst = newbuffer;
				auto newfill = min(m_fill, new_size);
				read(dst[0 .. newfill]);
				m_buffer = newbuffer;
				m_start = 0;
				m_fill = newfill;
			} else {
				m_buffer = new T[new_size];
			}
		}

		/// Resets the capacity to zero and explicitly frees the memory for the buffer.
		void dispose()
		{
			import core.memory : __delete;

			__delete(m_buffer);
			m_buffer = null;
			m_start = m_fill = 0;
		}
	}

	/// Returns a reference to the first element.
	@property ref inout(T) front() inout return { assert(!empty); return m_buffer[m_start]; }

	/// Returns a reference to the last element.
	@property ref inout(T) back() inout return { assert(!empty); return m_buffer[mod(m_start + m_fill - 1)]; }

	/// Removes all elements.
	void clear()
	{
		removeFrontN(length);
		assert(m_fill == 0);
		m_start = 0;
	}

	/// Adds elements to the back of the buffer.
	void put()(T itm) { assert(m_fill < m_buffer.length); move(itm, m_buffer[mod(m_start + m_fill++)]); }
	/// ditto
	void put(TC : T)(scope TC[] itms)
	{
		if (!itms.length) return;
		assert(m_fill + itms.length <= m_buffer.length);
		if (mod(m_start + m_fill) >= mod(m_start + m_fill + itms.length)) {
			size_t chunk1 = m_buffer.length - (m_start + m_fill);
			size_t chunk2 = itms.length - chunk1;
			m_buffer[m_start + m_fill .. m_buffer.length] = itms[0 .. chunk1];
			m_buffer[0 .. chunk2] = itms[chunk1 .. $];
		} else {
			m_buffer[mod(m_start + m_fill) .. mod(m_start + m_fill) + itms.length] = itms[];
		}
		m_fill += itms.length;
	}

	/** Adds elements to the back of the buffer without overwriting the buffer.

		This method is used in conjunction with `peekDst` for more efficient
		writing of multiple elements. `peekDst` is used to obtain a memory
		slice that can be directly written to, followed by calling `popFrontN`
		with the number of elements that were written to the slice.
	*/
	void putN(size_t n) { assert(m_fill+n <= m_buffer.length); m_fill += n; }

	/// Removes the first element from the buffer.
	void removeFront()
	{
		assert(!empty);
		static if (hasElaborateDestructor!T)
			destroy(m_buffer[m_start]);
		m_start = mod(m_start+1);
		m_fill--;
	}

	/// Removes the first N elements from the buffer.
	void removeFrontN(size_t n)
	{
		assert(length >= n);
		static if (hasElaborateDestructor!T) {
			foreach (i; 0 .. n)
				destroy(m_buffer[mod(m_start + i)]);
		}
		m_start = mod(m_start + n);
		m_fill -= n;
	}

	/// Removes the last element from the buffer.
	void removeBack()
	{
		assert(!empty);
		static if (hasElaborateDestructor!T)
			destroy(m_buffer[mod(m_start + m_fill - 1)]);
		m_fill--;
	}

	/// Removes the last N elements from the buffer.
	void removeBackN(size_t n)
	{
		assert(length >= n);
		static if (hasElaborateDestructor!T) {
			foreach (i; 0 .. n)
				destroy(m_buffer[mod(m_start + m_fill - n + i)]);
		}
		m_fill -= n;
	}

	/** Removes elements from the buffer.

		The argument to this method is a range of elements obtained by using
		the slice syntax (e.g. `ringbuffer[1 .. 2]`). Note that removing
		elements from the middle of an array is a `O(n)` operation.
	*/
	void linearRemove(Range r)
	{
		assert(r.m_buffer is m_buffer);
		if (m_start + m_fill > m_buffer.length) {
			assert(r.m_start >= m_start && r.m_start < m_buffer.length || r.m_start < mod(m_start+m_fill));
			if (r.m_start > m_start) {
				foreach (i; r.m_start .. m_buffer.length-1)
					move(m_buffer[i + 1], m_buffer[i]);
				move(m_buffer[0], m_buffer[$-1]);
				foreach (i; 0 .. mod(m_start + m_fill - 1))
					move(m_buffer[i + 1], m_buffer[i]);
			} else {
				foreach (i; r.m_start .. mod(m_start + m_fill - 1))
					move(m_buffer[i + 1], m_buffer[i]);
			}
		} else {
			assert(r.m_start >= m_start && r.m_start < m_start + m_fill);
			foreach (i; r.m_start .. m_start + m_fill - 1)
				move(m_buffer[i + 1], m_buffer[i]);
		}
		m_fill--;
		destroy(m_buffer[mod(m_start + m_fill)]); // TODO: only call destroy for non-POD T
	}

	/** Returns a slice of the first elements in the buffer.

		Note that not all elements will generally be part of the returned slice,
		because inserting elements will wrap around to the start of the internal
		buffer once the end is reached.
	*/
	inout(T)[] peek() inout return { return m_buffer[m_start .. min(m_start+m_fill, m_buffer.length)]; }

	/** Returns a slice of the unused buffer slots following the last element.

		This is used in conjunction with `putBackN` for efficient batch
		insertion of elements.
	*/
	T[] peekDst() return {
		if (!m_buffer.length) return null;
		if (m_start + m_fill < m_buffer.length) return m_buffer[m_start+m_fill .. $];
		else return m_buffer[mod(m_start+m_fill) .. m_start];
	}

	/** Moves elements from the front of the ring buffer into a supplied buffer.

	 	The first `dst.length` elements will be moved from the ring buffer into
	 	`dst`. `dst` must not be larger than the number of elements contained
	 	in the ring buffer.

	*/
	void read(scope T[] dst)
	{
		assert(dst.length <= length);
		if( !dst.length ) return;
		if( mod(m_start) >= mod(m_start+dst.length) ){
			size_t chunk1 = m_buffer.length - m_start;
			size_t chunk2 = dst.length - chunk1;
			static if (isCopyable!T) {
				dst[0 .. chunk1] = m_buffer[m_start .. $];
				dst[chunk1 .. $] = m_buffer[0 .. chunk2];
			} else {
				foreach (i; 0 .. chunk1) move(m_buffer[m_start+i], dst[i]);
				foreach (i; chunk1 .. this.length) move(m_buffer[i-chunk1], dst[i]);
			}
		} else {
			static if (isCopyable!T) {
				dst[] = m_buffer[m_start .. m_start+dst.length];
			} else {
				foreach (i; 0 .. dst.length)
					move(m_buffer[m_start + i], dst[i]);
			}
		}
		removeFrontN(dst.length);
	}

	/// Enables `foreach` iteration over all elements.
	int opApply(scope int delegate(ref T itm) @safe del)
	{
		if (m_start + m_fill > m_buffer.length) {
			foreach (i; m_start .. m_buffer.length)
				if (auto ret = del(m_buffer[i]))
					return ret;
			foreach (i; 0 .. mod(m_start + m_fill))
				if (auto ret = del(m_buffer[i]))
					return ret;
		} else {
			foreach (i; m_start .. m_start + m_fill)
				if (auto ret = del(m_buffer[i]))
					return ret;
		}
		return 0;
	}

	/// Enables `foreach` iteration over all elements along with their indices.
	int opApply(scope int delegate(size_t i, ref T itm) @safe del)
	{
		if (m_start + m_fill > m_buffer.length) {
			foreach (i; m_start .. m_buffer.length)
				if (auto ret = del(i - m_start, m_buffer[i]))
					return ret;
			foreach (i; 0 .. mod(m_start + m_fill))
				if (auto ret = del(i + m_buffer.length - m_start, m_buffer[i]))
					return ret;
		} else {
			foreach (i; m_start .. m_start + m_fill)
				if (auto ret = del(i - m_start, m_buffer[i]))
					return ret;
		}
		return 0;
	}

	/// Accesses the n-th element in the buffer.
	ref inout(T) opIndex(size_t idx) inout return { assert(idx < length); return m_buffer[mod(m_start + idx)]; }

	/// Returns a range spanning all elements currently in the buffer.
	Range opSlice() return { return Range(m_buffer, m_start, m_fill); }

	/// Returns a range spanning the given range of element indices.
	Range opSlice(size_t from, size_t to)
	return {
		assert(from <= to);
		assert(to <= m_fill);
		return Range(m_buffer, mod(m_start+from), to-from);
	}

	/// Returns the number of elements for using with the index/slice operators.
	size_t opDollar(size_t dim)() const if(dim == 0) { return length; }

	/// Represents a range of elements within the ring buffer.
	static struct Range {
		private {
			T[] m_buffer;
			size_t m_start;
			size_t m_length;
		}

		private this(T[] buffer, size_t start, size_t length)
		{
			m_buffer = buffer;
			m_start = start;
			m_length = length;
		}

		@property bool empty() const { return m_length == 0; }

		@property ref inout(T) front() inout return { assert(!empty); return m_buffer[m_start]; }

		void popFront()
		{
			assert(!empty);
			m_start++;
			m_length--;
			if (m_start >= m_buffer.length)
				m_start = 0;
		}
	}

	static if (N == 0) {
		private size_t mod(size_t n) const pure { return n % m_buffer.length; }
	} else static if( ((N - 1) & N) == 0 ){
		private static size_t mod(size_t n) pure { return n & (N - 1); }
	} else {
		private static size_t mod(size_t n) pure { return n % N; }
	}
}

@safe unittest {
	import std.range : isInputRange, isOutputRange;

	static assert(isInputRange!(RingBuffer!int.Range) && isOutputRange!(RingBuffer!int, int));

	RingBuffer!(int, 5) buf;
	assert(buf.length == 0 && buf.freeSpace == 5); buf.put(1); // |1 . . . .
	assert(buf.length == 1 && buf.freeSpace == 4); buf.put(2); // |1 2 . . .
	assert(buf.length == 2 && buf.freeSpace == 3); buf.put(3); // |1 2 3 . .
	assert(buf.length == 3 && buf.freeSpace == 2); buf.put(4); // |1 2 3 4 .
	assert(buf.length == 4 && buf.freeSpace == 1); buf.put(5); // |1 2 3 4 5
	assert(buf.length == 5 && buf.freeSpace == 0);
	assert(buf.front == 1);
	buf.removeFront(); // .|2 3 4 5
	assert(buf.front == 2);
	buf.removeFrontN(2); // . . .|4 5
	assert(buf.front == 4);
	assert(buf.length == 2 && buf.freeSpace == 3);
	buf.put([6, 7, 8]); // 6 7 8|4 5
	assert(buf.length == 5 && buf.freeSpace == 0);
	int[5] dst;
	buf.read(dst); // . . .|. .
	assert(dst == [4, 5, 6, 7, 8]);
	assert(buf.length == 0 && buf.freeSpace == 5);
	buf.put([1, 2]); // . . .|1 2
	assert(buf.length == 2 && buf.freeSpace == 3);
	buf.read(dst[0 .. 2]); //|. . . . .
	assert(dst[0 .. 2] == [1, 2]);

	buf.put([0, 0, 0, 1, 2]); //|0 0 0 1 2
	buf.removeFrontN(2); //. .|0 1 2
	buf.put([3, 4]); // 3 4|0 1 2
	foreach(i, item; buf) {
		assert(i == item);
	}
}

@safe unittest {
	static struct S {
	@safe:
		int* cnt;
		this(int* cnt) { this.cnt = cnt; (*cnt)++; }
		this(this) { if (cnt) (*cnt)++; }
		~this() { if (cnt) (*cnt)--; }
	}

	int* pcnt = new int;

	{
		RingBuffer!(S, 0) buf;
		buf.capacity = 1;
		auto s = S(pcnt);
		assert(*pcnt == 1);
		buf.put(S(pcnt));
		assert(*pcnt == 2);
		s = S.init;
		assert(*pcnt == 1);
		buf.removeBack();
		assert(*pcnt == 0);
		buf.put(S(pcnt));
		assert(*pcnt == 1);
		buf.capacity = 2;
		assert(*pcnt == 1);
	}
	assert(*pcnt == 0);

	{
		RingBuffer!(S, 0) buf;
		buf.capacity = 2;
		buf.put(S(pcnt));
		buf.put(S(pcnt));
		assert(*pcnt == 2);
		buf.removeFrontN(2);
		assert(*pcnt == 0);
		buf.put(S(pcnt));
		buf.put(S(pcnt));
		assert(*pcnt == 2);
		buf.linearRemove(buf[0 .. 1]);
		assert(*pcnt == 1);
	}
	assert(*pcnt == 0);
}
