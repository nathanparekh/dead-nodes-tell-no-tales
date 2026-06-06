CC ?= cc
CFLAGS ?= -Wall -Wextra -Werror -O2

.PHONY: all clean

all: counter

counter: counter.c
	$(CC) $(CFLAGS) -o $@ counter.c

clean:
	rm -f counter
